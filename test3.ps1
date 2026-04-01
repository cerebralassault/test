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


$callback = [Net.Security.RemoteCertificateValidationCallback]{
    param($sender, $cert, $chain, $errors)
    Write-Host "Subject: $($cert.Subject)"
    Write-Host "Issuer: $($cert.Issuer)"
    Write-Host "Errors: $errors"
    return $true
}

$uri = 'tas02.sls.update.microsoft.com'
$tcp = New-Object Net.Sockets.TcpClient($uri, 443)
$ssl = New-Object Net.Security.SslStream($tcp.GetStream(), $false, $callback)
try {
    $ssl.AuthenticateAsClient($uri)
    Write-Host "Protocol: $($ssl.SslProtocol)"
} catch {
    Write-Host "FAILED: $($_.Exception.Message)"
} finally {
    $ssl.Close()
    $tcp.Close()
}
