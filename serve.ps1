param([int]$Port = 3000)
$port = $Port
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$listener = [System.Net.HttpListener]::new()
$listener.Prefixes.Add("http://localhost:$port/")
$listener.Start()
Write-Host "Server running at http://localhost:$port/"

# Worker loop: multiple threads call GetContext() concurrently on the same
# listener (supported by HttpListener) so several requests are served in parallel.
$workerLoop = {
    param($listener, $root)
    while ($listener.IsListening) {
        try { $ctx = $listener.GetContext() } catch { break }
        $req = $ctx.Request
        $res = $ctx.Response
        $path = $req.Url.LocalPath
        if ($path -eq '/' -or $path -eq '') { $path = '/index.html' }
        $file = Join-Path $root $path.TrimStart('/')
        try {
            if (Test-Path $file -PathType Leaf) {
                $ext = [System.IO.Path]::GetExtension($file)
                $mime = switch ($ext) {
                    '.html' { 'text/html; charset=utf-8' }
                    '.css'  { 'text/css' }
                    '.js'   { 'application/javascript' }
                    '.png'  { 'image/png' }
                    '.jpg'  { 'image/jpeg' }
                    '.jpeg' { 'image/jpeg' }
                    '.webp' { 'image/webp' }
                    '.svg'  { 'image/svg+xml' }
                    '.mp4'  { 'video/mp4' }
                    '.mov'  { 'video/quicktime' }
                    default { 'application/octet-stream' }
                }
                $bytes = [System.IO.File]::ReadAllBytes($file)
                $res.ContentType = $mime
                $res.ContentLength64 = $bytes.Length
                $res.KeepAlive = $false
                $res.OutputStream.Write($bytes, 0, $bytes.Length)
            } else {
                $res.StatusCode = 404
                $res.KeepAlive = $false
            }
        } catch {
            try { $res.StatusCode = 500 } catch {}
        } finally {
            try { $res.OutputStream.Close() } catch {}
        }
    }
}

$pool = [runspacefactory]::CreateRunspacePool(1, 8)
$pool.Open()
$workers = @()
for ($i = 0; $i -lt 8; $i++) {
    $ps = [powershell]::Create()
    $ps.RunspacePool = $pool
    [void]$ps.AddScript($workerLoop).AddArgument($listener).AddArgument($root)
    $workers += [PSCustomObject]@{ PS = $ps; Handle = $ps.BeginInvoke() }
}

# Keep the main thread alive while workers serve requests.
while ($listener.IsListening) { Start-Sleep -Seconds 1 }
