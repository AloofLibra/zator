# Find one currently bindable port in the router's exact-tuple lease range.
function Get-AdaptiveAvailableSourcePort {
    for ($attempt = 0; $attempt -lt 64; $attempt++) {
        $port = Get-Random -Minimum 62000 -Maximum 63000
        $listener = $null
        try {
            $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Any, $port)
            $listener.Start()
            return [int]$port
        } catch {
        } finally {
            if ($listener) { $listener.Stop() }
        }
    }
    throw 'No free adaptive probe source port is available in 62000-62999.'
}
