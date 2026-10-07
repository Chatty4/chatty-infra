# Sets KEY=value in a .env file, but only while KEY still has a placeholder value: empty, change-me
# or dev-only-not-secret. A value someone already set is never overwritten. Line endings are kept.
#
#   set-env-value.ps1 -Path ..\chatty-chat\.env -Key CORE_SERVICE_TOKEN -Value <value>
#
# Prints "set" or "kept". Used by setup.bat.
param(
    [Parameter(Mandatory)][string]$Path,
    [Parameter(Mandatory)][string]$Key,
    [Parameter(Mandatory)][string]$Value
)

$text = [IO.File]::ReadAllText($Path)
$pattern = "(?m)^$([regex]::Escape($Key))=(change-me|dev-only-not-secret)?[ \t]*(?=\r?$)"
$regex = [regex]::new($pattern)

if (-not $regex.IsMatch($text)) {
    Write-Output "kept"
    exit 0
}

# A MatchEvaluator, so "$" in the value is never read as a regex group.
$text = $regex.Replace($text, { param($m) "$Key=$Value" }, 1)
[IO.File]::WriteAllText($Path, $text)
Write-Output "set"
