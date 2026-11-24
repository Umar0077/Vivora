$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$configPath = Join-Path $projectRoot 'lib/core/config/gemini_config.dart'
$examplePath = Join-Path $projectRoot 'lib/core/config/gemini_config.example.dart'
$placeholderText = [System.IO.File]::ReadAllText($examplePath)
if ($placeholderText -notmatch "apiKey = 'PASTE_YOUR_GEMINI_API_KEY_HERE'") { throw 'Example configuration must contain only the placeholder key.' }
$savedConfig = [System.IO.File]::ReadAllBytes($configPath)
try {
    [System.IO.File]::WriteAllBytes($configPath, [System.IO.File]::ReadAllBytes($examplePath))
    Push-Location $projectRoot
    try {
        & flutter build apk --debug
        if ($LASTEXITCODE -ne 0) { throw 'Placeholder debug build failed.' }
    } finally {
        Pop-Location
    }
} finally {
    # Restore the local secret from memory, including the original formatting.
    [System.IO.File]::WriteAllBytes($configPath, $savedConfig)
    [Array]::Clear($savedConfig, 0, $savedConfig.Length)
}
Write-Output 'Debug APK built with the placeholder; local key configuration restored.'
