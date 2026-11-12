# Prints a new VAPID key pair for Web Push as "<private> <public>": the raw P-256 private key
# (32 bytes) and the uncompressed public key (65 bytes), base64url without padding. Those are the
# forms pywebpush and the browser's pushManager.subscribe() take. Used by setup.bat.
#
#   vapid-keys.ps1
$ec = [Security.Cryptography.ECDsa]::Create([Security.Cryptography.ECCurve+NamedCurves]::nistP256)
$key = $ec.ExportParameters($true)

function ConvertTo-Base64Url([byte[]]$bytes) {
    [Convert]::ToBase64String($bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_')
}

$public = [byte[]](@(4) + $key.Q.X + $key.Q.Y)  # 0x04 = uncompressed point
Write-Output "$(ConvertTo-Base64Url $key.D) $(ConvertTo-Base64Url $public)"
