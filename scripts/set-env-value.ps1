# Sets KEY=value in a .env file, but only while KEY still has a placeholder value: empty, change-me
# or dev-only-not-secret. A value someone already set is never overwritten. Line endings are kept.
# With -Force, any value is replaced: for copies of a value whose source is another .env.
#
#   set-env-value.ps1 -Path ..\chatty-chat\.env -Key CORE_SERVICE_TOKEN -Value <value>
#   set-env-value.ps1 -Path ..\chatty-core\.env -Key MINIO_SECRET_KEY -Value <value> -Force
#
# Prints "set" or "kept" ("kept" with -Force: the value was already the same). Used by setup.bat.
param(
    [Parameter(Mandatory)][string]$Path,
    [Parameter(Mandatory)][string]$Key,
    [Parameter(Mandatory)][string]$Value,
    [switch]$Force
)

$text = [IO.File]::ReadAllText($Path)
$key = [regex]::Escape($Key)
if ($Force) {
    $pattern = "(?m)^$key=([^\r\n]*)"
} else {
    $pattern = "(?m)^$key=(change-me|dev-only-not-secret)?[ \t]*(?=\r?$)"
}
$regex = [regex]::new($pattern)
$match = $regex.Match($text)

if (-not $match.Success -or ($Force -and $match.Groups[1].Value.TrimEnd() -eq $Value)) {
    Write-Output "kept"
    exit 0
}

# A MatchEvaluator, so "$" in the value is never read as a regex group.
$text = $regex.Replace($text, { param($m) "$Key=$Value" }, 1)
[IO.File]::WriteAllText($Path, $text)
Write-Output "set"
