# test
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12; try { $r = [Net.HttpWebRequest]::Create('https://tas02.sls.update.microsoft.com'); $r.Timeout = 10000; $resp = $r.GetResponse(); $resp.Close(); Write-Host "OK - Issuer: $($r.ServicePoint.Certificate.Issuer)" } catch { Write-Host "FAILED: $($_.Exception.Message)"; if ($_.Exception.InnerException) { Write-Host "Inner: $($_.Exception.InnerException.Message)" }; try { Write-Host "Cert Issuer: $($r.ServicePoint.Certificate.Issuer)" } catch {} }

netsh winhttp show proxy
