param(
  [Parameter(Mandatory = $true)]
  [string]$Token,
  [ValidateSet('up', 'down', 'left', 'right', 'a', 'b', 'start', 'select')]
  [string]$Action = 'right',
  [ValidateRange(1, 500)]
  [int]$DurationMs = 100,
  [ValidateRange(1024, 65535)]
  [int]$Port = 38101
)

$uri = [Uri]::new(('http' + ':' + '//' + '127.0.0.1' + ':' + $Port + '/input'))
$body = ('{"action":"' + $Action + '","duration_ms":' + $DurationMs + '}')

[void][Reflection.Assembly]::LoadWithPartialName('System.Net.Http')
$client = $null
$request = $null
try {
  $client = [System.Net.Http.HttpClient]::new()
  $request = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Post, $uri)
  $request.Headers.Add('X-Remote-Token', $Token)
  $request.Content = [System.Net.Http.StringContent]::new(
    $body, [System.Text.Encoding]::UTF8, 'application/json')

  $response = $client.SendAsync($request).GetAwaiter().GetResult()
  $responseBody = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
  Write-Host ('HTTP {0} {1}' -f [int]$response.StatusCode, $response.ReasonPhrase)
  Write-Host $responseBody
  if (-not $response.IsSuccessStatusCode) { exit 1 }
}
finally {
  if ($request) { $request.Dispose() }
  if ($client) { $client.Dispose() }
}
