#!/usr/bin/env powershell
# Windows PowerShell 5.1+ compatible generic CLI-agent bridge.
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$Task,

    [Alias('t')]
    [string]$TaskText,

    [Alias('a')]
    [string]$Agent,

    [Alias('c')]
    [string]$Config,

    [Alias('w')]
    [string]$Workspace = (Get-Location).Path,

    [Alias('f')]
    [string[]]$File,

    [string]$Session,

    [Alias('Fresh')]
    [switch]$NewSession,

    [Alias('Stateless')]
    [switch]$NoSession,

    [string]$Model,

    [ValidateSet('low', 'medium', 'high')]
    [string]$Reasoning = 'medium',

    [string]$Sandbox,

    [switch]$ReadOnly,

    [switch]$FullAuto,

    [Alias('o')]
    [string]$Output,

    [switch]$Help
)

$ErrorActionPreference = 'Stop'

function Show-Usage {
    @'
Usage:
  ask_cli.ps1 <task> [options]
  ask_cli.ps1 -Agent <name> -Task <task> [options]

Task input:
  <task>                       First positional argument is the task text
  -Task, -t <text>             Alias for positional task

Agent selection:
  -Agent, -a <name>            Configured child CLI name or alias (default: config.defaultAgent)
  -Config, -c <path>           JSON config path (default: ../cli-agents.json)

File context:
  -File, -f <path>             Priority file path (repeatable)

Multi-turn:
  -Session <id>                Resume a previous session, if the agent config supports it
  -NewSession                  Ignore the saved session and start a fresh one
  -NoSession                   Do not resume or save any session for this run

Options:
  -Workspace, -w <path>        Workspace directory (default: current directory)
  -Model <name>                Model override, if the agent config has modelArgs
  -Reasoning <level>           Reasoning effort: low, medium, high (default: medium)
  -Sandbox <mode>              Sandbox mode override, if the agent config has sandboxArgs
  -ReadOnly                    Read-only mode, if the agent config has readOnlyArgs
  -FullAuto                    Full-auto mode, if the agent config has fullAutoArgs
  -Output, -o <path>           Output file path
  -Help                        Show this help

Output (on success):
  session_id=<id>              Printed when the child CLI exposes one
  output_path=<file>           Path to response markdown
'@
}

function Trim-Whitespace {
    param([string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return '' }
    return $Text.Trim() -replace '\s+', ' '
}

function Write-File-NoBOM {
    param([string]$Path, [string]$Content)
    $utf8NoBom = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::WriteAllText($Path, $Content, $utf8NoBom)
}

function Get-PropertyValue {
    param([object]$Object, [string]$Name)
    if (-not $Object) { return $null }
    $prop = $Object.PSObject.Properties[$Name]
    if ($prop) { return $prop.Value }
    return $null
}

function ConvertTo-StringArray {
    param([object]$Value)
    $items = @()
    if ($null -eq $Value) { return $items }
    if ($Value -is [string]) { return @($Value) }
    foreach ($item in $Value) {
        if ($null -ne $item) { $items += [string]$item }
    }
    return $items
}

function Expand-Template {
    param(
        [string]$Text,
        [hashtable]$Vars
    )
    if ($null -eq $Text) { return '' }
    $expanded = $Text
    foreach ($key in $Vars.Keys) {
        $expanded = $expanded.Replace('{' + $key + '}', [string]$Vars[$key])
    }
    return $expanded
}

function Expand-Args {
    param(
        [object]$InputArgs,
        [hashtable]$Vars
    )
    $expanded = @()
    foreach ($arg in (ConvertTo-StringArray $InputArgs)) {
        $expanded += Expand-Template -Text $arg -Vars $Vars
    }
    return $expanded
}

function Quote-WindowsArg {
    param([string]$Arg)
    if ($null -eq $Arg) { return '""' }
    if ($Arg -eq '') { return '""' }
    if ($Arg -notmatch '[\s&|<>^]') { return $Arg }
    return '"' + ($Arg -replace '"', '\"') + '"'
}

function Quote-PosixArg {
    param([string]$Arg)
    if ($null -eq $Arg) { return "''" }
    return "'" + ($Arg -replace "'", "'\''") + "'"
}

function Join-CommandLine {
    param(
        [string]$Command,
        [string[]]$InputArgs,
        [bool]$Windows
    )
    $parts = @()
    if ($Windows) {
        $parts += Quote-WindowsArg $Command
        foreach ($arg in $InputArgs) { $parts += Quote-WindowsArg $arg }
    } else {
        $parts += Quote-PosixArg $Command
        foreach ($arg in $InputArgs) { $parts += Quote-PosixArg $arg }
    }
    return ($parts -join ' ')
}

function Resolve-FileRef {
    param(
        [string]$Workspace,
        [string]$RawPath
    )

    $cleaned = Trim-Whitespace $RawPath
    if ([string]::IsNullOrWhiteSpace($cleaned)) { return '' }

    $cleaned = $cleaned -replace '#L\d+$', ''
    $cleaned = $cleaned -replace ':\d+(-\d+)?$', ''

    if (-not [System.IO.Path]::IsPathRooted($cleaned)) {
        $cleaned = Join-Path $Workspace $cleaned
    }

    if (Test-Path $cleaned) {
        return (Resolve-Path $cleaned -ErrorAction SilentlyContinue).Path
    }
    return $cleaned
}

function Test-ConfiguredCommand {
    param([string]$Command)
    if ([string]::IsNullOrWhiteSpace($Command)) {
        Write-Error "[ERROR] Agent config is missing command."
        exit 1
    }
    if ((Test-Path $Command -ErrorAction SilentlyContinue) -or (Get-Command $Command -ErrorAction SilentlyContinue)) {
        return
    }
    Write-Error "[ERROR] Missing configured command: $Command"
    exit 1
}

function Get-CodexJsonSummary {
    param(
        [string]$JsonText,
        [ref]$ThreadId
    )

    $outputContent = @()
    if ([string]::IsNullOrWhiteSpace($JsonText)) { return $outputContent }

    if ($JsonText -match '"thread_id"\s*:\s*"([^"]+)"') {
        $ThreadId.Value = $matches[1]
    }

    $jsonLines = $JsonText -split "`n" | Where-Object { $_.Trim() -and $_.TrimStart().StartsWith('{') }
    foreach ($line in $jsonLines) {
        try {
            $obj = $line | ConvertFrom-Json -ErrorAction SilentlyContinue
            if (-not $obj) { continue }

            if ($obj.type -eq 'item.completed' -and $obj.item) {
                $item = $obj.item

                if ($item.type -eq 'agent_message' -and $item.text) {
                    $outputContent += $item.text
                }

                if ($item.type -eq 'command_execution' -and $item.command) {
                    $cmd = $item.command -replace '^/bin/(zsh|bash) (-lc|-c) ', ''
                    $cmdPreview = $cmd.Substring(0, [Math]::Min(200, $cmd.Length))
                    $outPreview = ''
                    if ($item.aggregated_output) {
                        $outPreview = $item.aggregated_output.Substring(0, [Math]::Min(500, $item.aggregated_output.Length))
                    }
                    $outputContent += "### Shell: ``$cmdPreview```n$outPreview"
                }

                if ($item.type -eq 'tool_call' -and $item.name) {
                    $args = $null
                    try {
                        $args = $item.arguments | ConvertFrom-Json -ErrorAction SilentlyContinue
                    } catch {}

                    if ($item.name -eq 'write_file' -and $args.path) {
                        $outputContent += "### File written: $($args.path)"
                    }
                    if ($item.name -eq 'patch_file' -and $args.path) {
                        $outputContent += "### File patched: $($args.path)"
                    }
                    if ($item.name -eq 'shell' -and $args.command) {
                        $cmdPreview = $args.command.Substring(0, [Math]::Min(200, $args.command.Length))
                        $outPreview = ''
                        if ($item.output) {
                            $outPreview = $item.output.Substring(0, [Math]::Min(500, $item.output.Length))
                        }
                        $outputContent += "### Shell: ``$cmdPreview```n$outPreview"
                    }
                }
            }
        } catch {
            # Skip malformed JSON lines.
        }
    }
    return $outputContent
}

function ConvertTo-JsonObjects {
    param([string]$Text)

    $objects = @()
    if ([string]::IsNullOrWhiteSpace($Text)) { return $objects }

    $trimmed = $Text.Trim()
    try {
        $objects += ($trimmed | ConvertFrom-Json -ErrorAction Stop)
        return $objects
    } catch {}

    $jsonLines = $Text -split "`n" | Where-Object {
        $_.Trim() -and ($_.TrimStart().StartsWith('{') -or $_.TrimStart().StartsWith('['))
    }
    foreach ($line in $jsonLines) {
        try {
            $objects += ($line | ConvertFrom-Json -ErrorAction Stop)
        } catch {
            # Skip malformed JSON lines.
        }
    }
    return $objects
}

function Find-FirstJsonString {
    param(
        [object]$Object,
        [string[]]$Names
    )

    if ($null -eq $Object) { return $null }
    if ($Object -is [string]) { return $null }

    if ($Object -is [System.Collections.IEnumerable] -and -not ($Object -is [string])) {
        foreach ($item in $Object) {
            $found = Find-FirstJsonString -Object $item -Names $Names
            if (-not [string]::IsNullOrWhiteSpace($found)) { return $found }
        }
        return $null
    }

    foreach ($prop in $Object.PSObject.Properties) {
        if ($Names -contains $prop.Name -and $prop.Value -is [string] -and -not [string]::IsNullOrWhiteSpace($prop.Value)) {
            return [string]$prop.Value
        }
    }

    foreach ($prop in $Object.PSObject.Properties) {
        $found = Find-FirstJsonString -Object $prop.Value -Names $Names
        if (-not [string]::IsNullOrWhiteSpace($found)) { return $found }
    }
    return $null
}

function Add-JsonTextValues {
    param(
        [object]$Object,
        [System.Collections.Generic.List[string]]$Values
    )

    if ($null -eq $Object) { return }
    if ($Object -is [string]) { return }

    if ($Object -is [System.Collections.IEnumerable] -and -not ($Object -is [string])) {
        foreach ($item in $Object) {
            Add-JsonTextValues -Object $item -Values $Values
        }
        return
    }

    $textNames = @('result', 'text', 'content', 'output', 'response', 'message')
    foreach ($prop in $Object.PSObject.Properties) {
        if ($textNames -contains $prop.Name -and $prop.Value -is [string] -and -not [string]::IsNullOrWhiteSpace($prop.Value)) {
            $Values.Add([string]$prop.Value) | Out-Null
        }
    }

    foreach ($prop in $Object.PSObject.Properties) {
        Add-JsonTextValues -Object $prop.Value -Values $Values
    }
}

function Get-GenericJsonSummary {
    param(
        [string]$JsonText,
        [ref]$ThreadId
    )

    $objects = ConvertTo-JsonObjects -Text $JsonText
    $values = New-Object System.Collections.Generic.List[string]
    $sessionNames = @('session_id', 'sessionId', 'sessionID', 'thread_id', 'threadId')

    foreach ($obj in $objects) {
        if ([string]::IsNullOrWhiteSpace($ThreadId.Value)) {
            $foundSession = Find-FirstJsonString -Object $obj -Names $sessionNames
            if (-not [string]::IsNullOrWhiteSpace($foundSession)) {
                $ThreadId.Value = $foundSession
            }
        }
        Add-JsonTextValues -Object $obj -Values $values
    }

    $outputContent = @()
    foreach ($value in $values) {
        if (-not [string]::IsNullOrWhiteSpace($value) -and -not ($outputContent -contains $value)) {
            $outputContent += $value
        }
    }
    return $outputContent
}

function Get-SessionKey {
    param([string]$Agent, [string]$Workspace)

    $normalized = ($Agent + '|' + $Workspace).ToLowerInvariant()
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($normalized)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $hash = $sha.ComputeHash($bytes)
    } finally {
        $sha.Dispose()
    }
    $hex = -join ($hash | ForEach-Object { $_.ToString('x2') })
    return "$Agent-$($hex.Substring(0, 16))"
}

function Get-SavedSessionId {
    param([string]$Path, [string]$Key)

    if (-not (Test-Path $Path -PathType Leaf)) { return $null }
    try {
        $state = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -ErrorAction Stop
        $sessions = Get-PropertyValue -Object $state -Name 'sessions'
        $entry = Get-PropertyValue -Object $sessions -Name $Key
        if ($entry) {
            return [string](Get-PropertyValue -Object $entry -Name 'session_id')
        }
    } catch {
        return $null
    }
    return $null
}

function Save-SessionId {
    param(
        [string]$Path,
        [string]$Key,
        [string]$Agent,
        [string]$Workspace,
        [string]$SessionId
    )

    if ([string]::IsNullOrWhiteSpace($SessionId)) { return }

    $sessionsMap = [ordered]@{}
    if (Test-Path $Path -PathType Leaf) {
        try {
            $state = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -ErrorAction Stop
            $sessions = Get-PropertyValue -Object $state -Name 'sessions'
            if ($sessions) {
                foreach ($prop in $sessions.PSObject.Properties) {
                    $sessionsMap[$prop.Name] = $prop.Value
                }
            }
        } catch {
            $sessionsMap = [ordered]@{}
        }
    }

    $sessionsMap[$Key] = [ordered]@{
        agent = $Agent
        workspace = $Workspace
        session_id = $SessionId
        updated_utc = (Get-Date).ToUniversalTime().ToString('o')
    }

    $stateOut = [ordered]@{
        version = 1
        sessions = $sessionsMap
    }

    $dir = Split-Path $Path -Parent
    if (-not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    Write-File-NoBOM -Path $Path -Content ($stateOut | ConvertTo-Json -Depth 8)
}

if ($Help) {
    Show-Usage
    exit 0
}

if ([string]::IsNullOrEmpty($Task) -and -not [string]::IsNullOrEmpty($TaskText)) {
    $Task = $TaskText
}

if ($NewSession -and $NoSession) {
    Write-Error "[ERROR] -NewSession and -NoSession cannot be used together."
    exit 1
}

if ((-not [string]::IsNullOrEmpty($Session)) -and ($NewSession -or $NoSession)) {
    Write-Error "[ERROR] -Session cannot be combined with -NewSession or -NoSession."
    exit 1
}

if ([string]::IsNullOrEmpty($Config)) {
    $skillDir = Split-Path $PSScriptRoot -Parent
    $Config = Join-Path $skillDir 'cli-agents.json'
}
if (-not (Test-Path $Config -PathType Leaf)) {
    Write-Error "[ERROR] Config file does not exist: $Config"
    exit 1
}
$Config = (Resolve-Path $Config).Path
$configObject = Get-Content -LiteralPath $Config -Raw | ConvertFrom-Json

if ([string]::IsNullOrEmpty($Agent)) {
    $Agent = [string](Get-PropertyValue -Object $configObject -Name 'defaultAgent')
}
if ([string]::IsNullOrWhiteSpace($Agent)) {
    Write-Error "[ERROR] No agent specified and config.defaultAgent is empty."
    exit 1
}

$aliases = Get-PropertyValue -Object $configObject -Name 'aliases'
if ($aliases) {
    $canonicalAgent = Get-PropertyValue -Object $aliases -Name $Agent
    if ($canonicalAgent) {
        $Agent = [string]$canonicalAgent
    }
}

$agents = Get-PropertyValue -Object $configObject -Name 'agents'
$agentConfig = Get-PropertyValue -Object $agents -Name $Agent
if (-not $agentConfig) {
    $names = ($agents.PSObject.Properties.Name -join ', ')
    Write-Error "[ERROR] Unknown agent '$Agent'. Available agents: $names"
    exit 1
}

if (-not (Test-Path $Workspace -PathType Container)) {
    Write-Error "[ERROR] Workspace does not exist: $Workspace"
    exit 1
}
$Workspace = (Resolve-Path $Workspace).Path

$Task = Trim-Whitespace $Task
if ([string]::IsNullOrEmpty($Task)) {
    Write-Error "[ERROR] Request text is empty. Pass a positional arg or -Task."
    exit 1
}

$fileBlock = ''
if ($File -and $File.Count -gt 0) {
    $fileBlock = "`nPriority files (read these first before making changes):"
    foreach ($ref in $File) {
        $resolved = Resolve-FileRef -Workspace $Workspace -RawPath $ref
        if (-not [string]::IsNullOrEmpty($resolved)) {
            $existsTag = if (Test-Path $resolved) { 'exists' } else { 'missing' }
            $fileBlock += "`n- $resolved ($existsTag)"
        }
    }
}

$prompt = $Task
if (-not [string]::IsNullOrEmpty($fileBlock)) {
    $prompt += $fileBlock
}

$timestamp = (Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss')
$skillRoot = Split-Path $PSScriptRoot -Parent
$runtimeDirName = [string](Get-PropertyValue -Object $configObject -Name 'runtimeDir')
if ([string]::IsNullOrWhiteSpace($runtimeDirName)) { $runtimeDirName = '.runtime' }
$runtimeDir = if ([System.IO.Path]::IsPathRooted($runtimeDirName)) { $runtimeDirName } else { Join-Path $skillRoot $runtimeDirName }

if (-not (Test-Path $runtimeDir)) {
    New-Item -ItemType Directory -Path $runtimeDir -Force | Out-Null
}

if ([string]::IsNullOrEmpty($Output)) {
    $Output = Join-Path $runtimeDir "$timestamp-$Agent.md"
}

$sessionStatePath = Join-Path $runtimeDir 'sessions.json'
$sessionKey = Get-SessionKey -Agent $Agent -Workspace $Workspace
$explicitSession = -not [string]::IsNullOrEmpty($Session)

if (-not $explicitSession -and -not $NewSession -and -not $NoSession) {
    $savedSession = Get-SavedSessionId -Path $sessionStatePath -Key $sessionKey
    if (-not [string]::IsNullOrWhiteSpace($savedSession)) {
        $Session = $savedSession
        Write-Verbose "Auto-resuming $Agent session $Session"
    }
}

$tempDir = [System.IO.Path]::GetTempPath()
$guid = [guid]::NewGuid().ToString()
$promptFile = Join-Path $tempDir "cli_agent_prompt_$guid.txt"

$vars = @{
    agent = $Agent
    workspace = $Workspace
    task = $Task
    prompt = $prompt
    prompt_file = $promptFile
    session = $Session
    model = $Model
    reasoning = $Reasoning
    sandbox = $Sandbox
    output = $Output
}

$command = Expand-Template -Text ([string](Get-PropertyValue -Object $agentConfig -Name 'command')) -Vars $vars
Test-ConfiguredCommand $command

$isResumeMode = -not [string]::IsNullOrEmpty($Session)
if ($isResumeMode) {
    $rawArgs = Get-PropertyValue -Object $agentConfig -Name 'resumeArgs'
    if (-not $rawArgs) {
        Write-Error "[ERROR] Agent '$Agent' does not define resumeArgs."
        exit 1
    }
    $childArgs = Expand-Args -InputArgs $rawArgs -Vars $vars
} else {
    $childArgs = Expand-Args -InputArgs (Get-PropertyValue -Object $agentConfig -Name 'newArgs') -Vars $vars

    if ($ReadOnly) {
        $childArgs += Expand-Args -InputArgs (Get-PropertyValue -Object $agentConfig -Name 'readOnlyArgs') -Vars $vars
    } elseif (-not [string]::IsNullOrEmpty($Sandbox)) {
        $childArgs += Expand-Args -InputArgs (Get-PropertyValue -Object $agentConfig -Name 'sandboxArgs') -Vars $vars
    } elseif ($FullAuto) {
        $childArgs += Expand-Args -InputArgs (Get-PropertyValue -Object $agentConfig -Name 'fullAutoArgs') -Vars $vars
    }

    if (-not [string]::IsNullOrEmpty($Model)) {
        $childArgs += Expand-Args -InputArgs (Get-PropertyValue -Object $agentConfig -Name 'modelArgs') -Vars $vars
    }
}

$promptMode = [string](Get-PropertyValue -Object $agentConfig -Name 'promptMode')
if ([string]::IsNullOrWhiteSpace($promptMode)) { $promptMode = 'stdin' }

if ($promptMode -eq 'argument') {
    $promptArgs = Get-PropertyValue -Object $agentConfig -Name 'promptArgs'
    if (-not $promptArgs) { $promptArgs = @('{prompt}') }
    $childArgs += Expand-Args -InputArgs $promptArgs -Vars $vars
} elseif ($promptMode -eq 'file') {
    $promptArgs = Get-PropertyValue -Object $agentConfig -Name 'promptArgs'
    if (-not $promptArgs) { $promptArgs = @('{prompt_file}') }
    $childArgs += Expand-Args -InputArgs $promptArgs -Vars $vars
}

$workingDirectory = Expand-Template -Text ([string](Get-PropertyValue -Object $agentConfig -Name 'workingDirectory')) -Vars $vars
if ([string]::IsNullOrWhiteSpace($workingDirectory)) { $workingDirectory = $Workspace }

$outputMode = [string](Get-PropertyValue -Object $agentConfig -Name 'outputMode')
if ([string]::IsNullOrWhiteSpace($outputMode)) { $outputMode = 'text' }

$progressPrefix = [string](Get-PropertyValue -Object $agentConfig -Name 'progressPrefix')
if ([string]::IsNullOrWhiteSpace($progressPrefix)) { $progressPrefix = "[$Agent]" }

$invocation = [string](Get-PropertyValue -Object $agentConfig -Name 'invocation')
if ([string]::IsNullOrWhiteSpace($invocation)) { $invocation = 'direct' }

$stderrOutput = New-Object System.Text.StringBuilder
$stdoutOutput = New-Object System.Text.StringBuilder

$cleanupScript = {
    Remove-Item -Path $promptFile -Force -ErrorAction SilentlyContinue
}

try {
    Write-File-NoBOM -Path $promptFile -Content $prompt

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $isWindowsRuntime = ($IsWindows -or $PSVersionTable.PSVersion.Major -le 5)

    if ($invocation -eq 'shell') {
        if ($isWindowsRuntime) {
            $psi.FileName = 'cmd.exe'
            $psi.Arguments = '/d /s /c ' + (Join-CommandLine -Command $command -InputArgs $childArgs -Windows $true)
        } else {
            $psi.FileName = '/bin/sh'
            $psi.Arguments = '-lc ' + (Quote-PosixArg (Join-CommandLine -Command $command -InputArgs $childArgs -Windows $false))
        }
    } else {
        $psi.FileName = $command
        $psi.Arguments = if ($isWindowsRuntime) {
            ($childArgs | ForEach-Object { Quote-WindowsArg $_ }) -join ' '
        } else {
            ($childArgs | ForEach-Object { Quote-PosixArg $_ }) -join ' '
        }
    }

    Write-Verbose "Child command: $($psi.FileName) $($psi.Arguments)"

    $psi.WorkingDirectory = $workingDirectory
    $psi.UseShellExecute = $false
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
    $psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $psi

    $stdoutData = [pscustomobject]@{
        Builder = $stdoutOutput
        Prefix = $progressPrefix
        Mode = $outputMode
    }
    $stderrData = [pscustomobject]@{
        Builder = $stderrOutput
    }

    $stdOutAction = {
        param([object]$sender, [System.Diagnostics.DataReceivedEventArgs]$e)
        if ($e.Data) {
            $data = $Event.MessageData
            $line = $e.Data -replace "`r", ''
            $line = $line -replace [char]4, ''

            [System.Threading.Monitor]::Enter($data.Builder)
            try {
                $data.Builder.AppendLine($line) | Out-Null
            } finally {
                [System.Threading.Monitor]::Exit($data.Builder)
            }

            if ($data.Mode -eq 'codex-json' -and $line.StartsWith('{')) {
                if ($line -match '"item\.started"' -and $line -match '"command_execution"') {
                    try {
                        $json = $line | ConvertFrom-Json -ErrorAction SilentlyContinue
                        $cmd = $json.item.command
                        if ($cmd) {
                            $cmd = $cmd -replace '^/bin/(zsh|bash) (-lc|-c) ', ''
                            if ($cmd.Length -gt 100) { $cmd = $cmd.Substring(0, 100) }
                            Write-Host "$($data.Prefix) > $cmd" -ForegroundColor Gray
                        }
                    } catch {}
                }
                if ($line -match '"item\.completed"' -and $line -match '"agent_message"') {
                    try {
                        $json = $line | ConvertFrom-Json -ErrorAction SilentlyContinue
                        $text = $json.item.text
                        if ($text) {
                            $preview = $text.Split("`n")[0]
                            if ($preview.Length -gt 120) { $preview = $preview.Substring(0, 120) }
                            Write-Host "$($data.Prefix) $preview" -ForegroundColor Gray
                        }
                    } catch {}
                }
            } elseif ($data.Mode -eq 'generic-json' -or $data.Mode -eq 'json') {
                $trimmedLine = $line.TrimStart()
                if (-not ($trimmedLine.StartsWith('{') -or $trimmedLine.StartsWith('['))) {
                    $preview = $line
                    if ($preview.Length -gt 120) { $preview = $preview.Substring(0, 120) }
                    Write-Host "$($data.Prefix) $preview" -ForegroundColor Gray
                }
            } elseif ($data.Mode -ne 'codex-json') {
                $preview = $line
                if ($preview.Length -gt 120) { $preview = $preview.Substring(0, 120) }
                Write-Host "$($data.Prefix) $preview" -ForegroundColor Gray
            }
        }
    }

    $stdErrAction = {
        param([object]$sender, [System.Diagnostics.DataReceivedEventArgs]$e)
        if ($e.Data) {
            $data = $Event.MessageData
            [System.Threading.Monitor]::Enter($data.Builder)
            try {
                $data.Builder.AppendLine($e.Data) | Out-Null
            } finally {
                [System.Threading.Monitor]::Exit($data.Builder)
            }
            Write-Host $e.Data -ForegroundColor Yellow
        }
    }

    $stdOutEvent = Register-ObjectEvent -InputObject $process -EventName OutputDataReceived -Action $stdOutAction -MessageData $stdoutData
    $stdErrEvent = Register-ObjectEvent -InputObject $process -EventName ErrorDataReceived -Action $stdErrAction -MessageData $stderrData

    try {
        $process.Start() | Out-Null
        $process.BeginOutputReadLine()
        $process.BeginErrorReadLine()

        if ($promptMode -eq 'stdin') {
            $process.StandardInput.Write($prompt)
        }
        $process.StandardInput.Close()

        $process.WaitForExit()
        $exitCode = $process.ExitCode
    } finally {
        Unregister-Event -SourceIdentifier $stdOutEvent.Name -ErrorAction SilentlyContinue
        Unregister-Event -SourceIdentifier $stdErrEvent.Name -ErrorAction SilentlyContinue
        $process.Dispose()
    }

    $stdoutText = $stdoutOutput.ToString()
    $stderrText = $stderrOutput.ToString()
    $hasValidOutput = -not [string]::IsNullOrWhiteSpace($stdoutText)

    if ($exitCode -ne 0 -and -not $hasValidOutput) {
        Write-Error "[ERROR] Agent '$Agent' exited with code $exitCode"
        if (-not [string]::IsNullOrWhiteSpace($stderrText)) { Write-Error $stderrText }
        exit 1
    }

    $threadId = $null
    $outputContent = @()

    if ($outputMode -eq 'codex-json') {
        $threadIdRef = [ref]$threadId
        $outputContent = Get-CodexJsonSummary -JsonText $stdoutText -ThreadId $threadIdRef
        $threadId = $threadIdRef.Value
        if ($isResumeMode -and [string]::IsNullOrWhiteSpace($threadId)) {
            $threadId = $Session
        }
    } elseif ($outputMode -eq 'generic-json' -or $outputMode -eq 'json') {
        $threadIdRef = [ref]$threadId
        $outputContent = Get-GenericJsonSummary -JsonText $stdoutText -ThreadId $threadIdRef
        $threadId = $threadIdRef.Value

        $sessionRegex = [string](Get-PropertyValue -Object $agentConfig -Name 'sessionIdRegex')
        if ([string]::IsNullOrWhiteSpace($threadId) -and -not [string]::IsNullOrWhiteSpace($sessionRegex) -and $stdoutText -match $sessionRegex) {
            $threadId = $matches[1]
        }
        if ($isResumeMode -and [string]::IsNullOrWhiteSpace($threadId)) {
            $threadId = $Session
        }
    } else {
        $trimmed = $stdoutText.Trim()
        if (-not [string]::IsNullOrWhiteSpace($trimmed)) {
            $outputContent += $trimmed
        }
        $sessionRegex = [string](Get-PropertyValue -Object $agentConfig -Name 'sessionIdRegex')
        if (-not [string]::IsNullOrWhiteSpace($sessionRegex) -and $stdoutText -match $sessionRegex) {
            $threadId = $matches[1]
        } elseif ($isResumeMode) {
            $threadId = $Session
        }
    }

    if (-not $NoSession -and -not [string]::IsNullOrWhiteSpace($threadId)) {
        Save-SessionId -Path $sessionStatePath -Key $sessionKey -Agent $Agent -Workspace $Workspace -SessionId $threadId
    }

    $outputDir = Split-Path $Output -Parent
    if (-not (Test-Path $outputDir)) {
        New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
    }

    if ($outputContent.Count -gt 0) {
        Write-File-NoBOM -Path $Output -Content ($outputContent -join "`n")
    } else {
        Write-File-NoBOM -Path $Output -Content "(no response from $Agent)"
    }

    if (-not [string]::IsNullOrEmpty($threadId)) {
        Write-Output "session_id=$threadId"
    }
    Write-Output "output_path=$Output"
} finally {
    & $cleanupScript
}
