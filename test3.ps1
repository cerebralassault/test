$tcp = New-Object Net.Sockets.TcpClient('www.microsoft.com', 443)
$ssl = New-Object Net.Security.SslStream($tcp.GetStream())
try {
    $ssl.AuthenticateAsClient('www.microsoft.com')
    Write-Host "OK - Protocol: $($ssl.SslProtocol)"
} catch {
    Write-Host "FAILED: $($_.Exception.Message)"
} finally {
    $ssl.Close()
    $tcp.Close()
}
