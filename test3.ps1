$uri = 'tas02.sls.update.microsoft.com'
$tcp = New-Object Net.Sockets.TcpClient($uri, 443)
$ssl = New-Object Net.Security.SslStream($tcp.GetStream())
try {
    $ssl.AuthenticateAsClient($uri)
    Write-Host "Protocol: $($ssl.SslProtocol) Cipher: $($ssl.CipherAlgorithm) Strength: $($ssl.CipherStrength)"
} catch {
    Write-Host "FAILED: $($_.Exception.Message)"
    if ($_.Exception.InnerException) { Write-Host "Inner: $($_.Exception.InnerException.Message)" }
} finally {
    $ssl.Close()
    $tcp.Close()
}
