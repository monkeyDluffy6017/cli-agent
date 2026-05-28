param()

$ErrorActionPreference = 'Stop'

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) {
        throw $Message
    }
}

function Get-JsonProperty {
    param([object]$Object, [string]$Name)
    if ($null -eq $Object) { return $null }
    $prop = $Object.PSObject.Properties[$Name]
    if ($prop) { return $prop.Value }
    return $null
}

function Assert-ArrayContainsSubsequence {
    param(
        [object[]]$Actual,
        [string[]]$Expected,
        [string]$Message
    )

    $actualStrings = @($Actual | ForEach-Object { [string]$_ })
    if ($Expected.Count -eq 0) { return }
    if ($actualStrings.Count -lt $Expected.Count) {
        throw "$Message. Actual: $($actualStrings -join ' ')"
    }

    for ($i = 0; $i -le ($actualStrings.Count - $Expected.Count); $i++) {
        $matched = $true
        for ($j = 0; $j -lt $Expected.Count; $j++) {
            if ($actualStrings[$i + $j] -ne $Expected[$j]) {
                $matched = $false
                break
            }
        }
        if ($matched) { return }
    }

    throw "$Message. Actual: $($actualStrings -join ' ')"
}

function Read-JsonFile {
    param([string]$Path)
    return Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
}

$repoRoot = Split-Path $PSScriptRoot -Parent
$bridge = Join-Path $repoRoot 'scripts/ask_cli.ps1'
$configPath = Join-Path $repoRoot 'cli-agents.json'
$opencodePermissionConfigPath = Join-Path $repoRoot 'config/opencode-full-permissions.json'

$repoConfig = Read-JsonFile $configPath
Assert-True ([int]$repoConfig.runtimeRetentionDays -eq 3) 'Default runtime retention should be 3 days.'

$claudeAgent = $repoConfig.agents.'claude-code'
Assert-True ([bool](Get-JsonProperty -Object $claudeAgent -Name 'defaultFullAuto')) 'claude-code should default to full-auto permission mode.'
Assert-ArrayContainsSubsequence -Actual $claudeAgent.fullAutoArgs -Expected @('--permission-mode', 'bypassPermissions') -Message 'claude-code fullAutoArgs should bypass permissions.'

$codexAgent = $repoConfig.agents.codex
Assert-True ([bool](Get-JsonProperty -Object $codexAgent -Name 'defaultFullAuto')) 'codex should default to full-auto permission mode.'
Assert-ArrayContainsSubsequence -Actual $codexAgent.fullAutoArgs -Expected @('--sandbox', 'danger-full-access', '--ask-for-approval', 'never') -Message 'codex fullAutoArgs should disable sandbox and approval prompts.'

$csAgent = $repoConfig.agents.cs
Assert-True ([bool](Get-JsonProperty -Object $csAgent -Name 'defaultFullAuto')) 'cs should default to full-auto permission mode.'
Assert-True ($csAgent.environment.OPENCODE_CONFIG -eq '{skill_root}/config/opencode-full-permissions.json') 'cs should load the bundled OpenCode permission config.'
Assert-True ($csAgent.environmentFiles.OPENCODE_CONFIG_CONTENT -eq '{skill_root}/config/opencode-full-permissions.json') 'cs should inline the bundled OpenCode permission config as a runtime override.'

$opencodeAgent = $repoConfig.agents.opencode
Assert-True ($null -ne $opencodeAgent) 'opencode agent should be configured.'
Assert-True ([bool](Get-JsonProperty -Object $opencodeAgent -Name 'defaultFullAuto')) 'opencode should default to full-auto permission mode.'
Assert-True ($opencodeAgent.environment.OPENCODE_CONFIG -eq '{skill_root}/config/opencode-full-permissions.json') 'opencode should load the bundled OpenCode permission config.'
Assert-True ($opencodeAgent.environmentFiles.OPENCODE_CONFIG_CONTENT -eq '{skill_root}/config/opencode-full-permissions.json') 'opencode should inline the bundled OpenCode permission config as a runtime override.'
Assert-True ($repoConfig.aliases.opencode -eq 'opencode') 'opencode alias should resolve to the opencode agent.'

Assert-True (Test-Path $opencodePermissionConfigPath -PathType Leaf) 'Bundled OpenCode permission config should exist.'
$opencodePermissionConfig = Read-JsonFile $opencodePermissionConfigPath
$permission = $opencodePermissionConfig.permission
foreach ($name in @('*', 'read', 'edit', 'bash', 'glob', 'grep', 'webfetch', 'websearch', 'task', 'skill', 'lsp', 'question', 'doom_loop')) {
    Assert-True ((Get-JsonProperty -Object $permission -Name $name) -eq 'allow') "OpenCode permission '$name' should be allowed."
}
$externalDirectory = $permission.external_directory
foreach ($pathPattern in @('/**', 'C:/**', 'D:/**', 'E:/**', 'F:/**', 'G:/**')) {
    Assert-True ((Get-JsonProperty -Object $externalDirectory -Name $pathPattern) -eq 'allow') "OpenCode external_directory '$pathPattern' should be allowed."
}

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) "cli-agent-permission-test-$([guid]::NewGuid().ToString('N'))"
$workspace = Join-Path $tempRoot 'workspace'
$runtimeDir = Join-Path $tempRoot 'runtime'
$fakeAgentPath = Join-Path $tempRoot 'fake-agent.ps1'
$fakeAgentCmdPath = Join-Path $tempRoot 'fake-agent.cmd'
$testConfigPath = Join-Path $tempRoot 'cli-agents-test.json'

try {
    New-Item -ItemType Directory -Path $workspace, $runtimeDir -Force | Out-Null
    $psExe = (Get-Process -Id $PID).Path

    @'
param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$CapturedArgs
)

$stdinText = [Console]::In.ReadToEnd()
$capture = [ordered]@{
    args = $CapturedArgs
    stdin = $stdinText
    env = [ordered]@{
        CLI_AGENT_SKILL_ROOT = $env:CLI_AGENT_SKILL_ROOT
        CLI_AGENT_WORKSPACE = $env:CLI_AGENT_WORKSPACE
        OPENCODE_CONFIG = $env:OPENCODE_CONFIG
        CLI_AGENT_PERMISSION_CONTENT = $env:CLI_AGENT_PERMISSION_CONTENT
    }
}

$capture | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $env:CLI_AGENT_CAPTURE -Encoding UTF8
Write-Output '{"session_id":"fake-session","result":"ok"}'
'@ | Set-Content -LiteralPath $fakeAgentPath -Encoding UTF8

    @"
@echo off
"$psExe" -NoProfile -ExecutionPolicy Bypass -File "$fakeAgentPath" %*
"@ | Set-Content -LiteralPath $fakeAgentCmdPath -Encoding ASCII

    $testConfig = [ordered]@{
        defaultAgent = 'fake'
        runtimeDir = $runtimeDir
        aliases = [ordered]@{
            fake = 'fake'
        }
        agents = [ordered]@{
            fake = [ordered]@{
                command = $psExe
                invocation = 'direct'
                promptMode = 'argument'
                newArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $fakeAgentPath, 'new')
                resumeArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $fakeAgentPath, 'resume', '{session}')
                promptArgs = @('{prompt}')
                fullAutoArgs = @('--permission-mode', 'bypassPermissions')
                defaultFullAuto = $true
                outputMode = 'generic-json'
                workingDirectory = '{workspace}'
                environment = [ordered]@{
                    CLI_AGENT_CAPTURE = '{output}.capture.json'
                    CLI_AGENT_SKILL_ROOT = '{skill_root}'
                    CLI_AGENT_WORKSPACE = '{workspace}'
                    OPENCODE_CONFIG = '{skill_root}/config/opencode-full-permissions.json'
                }
                environmentFiles = [ordered]@{
                    CLI_AGENT_PERMISSION_CONTENT = '{skill_root}/config/opencode-full-permissions.json'
                }
            }
            'fake-before' = [ordered]@{
                command = $fakeAgentCmdPath
                invocation = 'shell'
                promptMode = 'argument'
                newArgs = @('new')
                promptArgs = @('{prompt}')
                fullAutoArgs = @('--sandbox', 'danger-full-access', '--ask-for-approval', 'never')
                defaultFullAuto = $true
                permissionArgsPosition = 'beforeBase'
                outputMode = 'generic-json'
                workingDirectory = '{workspace}'
                environment = [ordered]@{
                    CLI_AGENT_CAPTURE = '{output}.capture.json'
                }
            }
        }
    }
    $testConfig | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $testConfigPath -Encoding UTF8

    $oldMarkdown = Join-Path $runtimeDir 'old-output.md'
    $oldTranscript = Join-Path $runtimeDir 'old-output.jsonl'
    $oldPrompt = Join-Path $runtimeDir 'old-prompt.txt'
    $freshMarkdown = Join-Path $runtimeDir 'fresh-output.md'
    $oldSessionState = Join-Path $runtimeDir 'sessions.json'
    foreach ($path in @($oldMarkdown, $oldTranscript, $oldPrompt, $freshMarkdown, $oldSessionState)) {
        Set-Content -LiteralPath $path -Value 'fixture' -Encoding UTF8
    }
    $olderThanRetention = (Get-Date).AddDays(-4)
    foreach ($path in @($oldMarkdown, $oldTranscript, $oldPrompt, $oldSessionState)) {
        (Get-Item -LiteralPath $path).LastWriteTime = $olderThanRetention
    }
    (Get-Item -LiteralPath $freshMarkdown).LastWriteTime = (Get-Date).AddDays(-2)

    $newOutput = Join-Path $runtimeDir 'new-output.md'
    $newBridgeOutput = & $psExe -NoProfile -ExecutionPolicy Bypass -File $bridge -Agent fake -Config $testConfigPath -Workspace $workspace -Output $newOutput -NoSession -NoSummary 'new task' 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "New-session bridge invocation failed: $newBridgeOutput"
    }
    Assert-True (-not (Test-Path $oldMarkdown -PathType Leaf)) 'Runtime cleanup should remove .md files older than 3 days.'
    Assert-True (-not (Test-Path $oldTranscript -PathType Leaf)) 'Runtime cleanup should remove .jsonl files older than 3 days.'
    Assert-True (-not (Test-Path $oldPrompt -PathType Leaf)) 'Runtime cleanup should remove .txt files older than 3 days.'
    Assert-True (Test-Path $freshMarkdown -PathType Leaf) 'Runtime cleanup should keep files newer than 3 days.'
    Assert-True (Test-Path $oldSessionState -PathType Leaf) 'Runtime cleanup should keep sessions.json even when old.'

    $newCapture = Read-JsonFile "$newOutput.capture.json"
    Assert-ArrayContainsSubsequence -Actual $newCapture.args -Expected @('new', '--permission-mode', 'bypassPermissions', 'new task') -Message 'Full-auto args should be applied to new sessions before the prompt.'
    Assert-True ($newCapture.env.CLI_AGENT_SKILL_ROOT -eq $repoRoot) 'Environment templates should expand skill_root.'
    Assert-True ($newCapture.env.CLI_AGENT_WORKSPACE -eq (Resolve-Path $workspace).Path) 'Environment templates should expand workspace.'
    Assert-True ((Test-Path $newCapture.env.OPENCODE_CONFIG -PathType Leaf) -and $newCapture.env.OPENCODE_CONFIG.EndsWith('config/opencode-full-permissions.json')) 'Environment should point OPENCODE_CONFIG at the bundled permission config.'
    $inlinePermissionConfig = $newCapture.env.CLI_AGENT_PERMISSION_CONTENT | ConvertFrom-Json
    Assert-True ($inlinePermissionConfig.permission.'*' -eq 'allow') 'environmentFiles should load file content into the configured env var.'

    $resumeOutput = Join-Path $runtimeDir 'resume-output.md'
    $resumeBridgeOutput = & $psExe -NoProfile -ExecutionPolicy Bypass -File $bridge -Agent fake -Config $testConfigPath -Workspace $workspace -Output $resumeOutput -Session saved-session -NoSummary 'resume task' 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Resume bridge invocation failed: $resumeBridgeOutput"
    }
    $resumeCapture = Read-JsonFile "$resumeOutput.capture.json"
    Assert-ArrayContainsSubsequence -Actual $resumeCapture.args -Expected @('resume', 'saved-session', '--permission-mode', 'bypassPermissions', 'resume task') -Message 'Full-auto args should be applied to resumed sessions before the prompt.'

    $beforeOutput = Join-Path $runtimeDir 'before-output.md'
    $beforeBridgeOutput = & $psExe -NoProfile -ExecutionPolicy Bypass -File $bridge -Agent fake-before -Config $testConfigPath -Workspace $workspace -Output $beforeOutput -NoSession -NoSummary 'before task' 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Before-base bridge invocation failed: $beforeBridgeOutput"
    }
    $beforeCapture = Read-JsonFile "$beforeOutput.capture.json"
    Assert-ArrayContainsSubsequence -Actual $beforeCapture.args -Expected @('--sandbox', 'danger-full-access', '--ask-for-approval', 'never', 'new', 'before task') -Message 'permissionArgsPosition=beforeBase should place permission args before base args.'
} finally {
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Output 'bridge permission tests passed'
