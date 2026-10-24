# Golf Crew Tee Sheet: pulls GolfNow tee times within 30 miles of The Colony and saves them
# to the page's database (Firestore meta/tee). GitHub runs it every 3 hours
# (.github/workflows/golf-tee.yml). Runs in Windows PowerShell 5.1 or pwsh.

$ErrorActionPreference = "Stop"
$Lat = 33.089; $Lon = -96.886; $Radius = 30
$Api = "https://www.golfnow.com/api/tee-times/tee-time-results"
$Doc = "https://firestore.googleapis.com/v1/projects/golf-crew-tee-sheet/databases/(default)/documents/meta/tee"
$Head = @{ "User-Agent" = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0 Safari/537.36"; "Accept" = "application/json" }
$Players = @{ Any = "1234"; One = "1"; Two = "2"; Three = "3"; Four = "4"; OneTwo = "12"; OneTwoThree = "123"; TwoThree = "23"; TwoFour = "24"; TwoThreeFour = "234"; ThreeFour = "34" }

function Search($date, $extra) {
  $b = @{ Radius = $Radius; Latitude = $Lat; Longitude = $Lon; PageSize = 30; PageNumber = 0; SearchType = 0; SortBy = "Date"; SortDirection = 0
    Date = $date; HotDealsOnly = $false; BestDealsOnly = $false; PriceMin = 0; PriceMax = 10000; Players = 0; TimePeriod = 3; Holes = 3; RateType = "all"
    TimeMin = 10; TimeMax = 42; SortByRollup = "Date.MinDate"; View = "Tile"; ExcludeFeaturedFacilities = $true; TeeTimeCount = 50; PromotedCampaignsOnly = $false }
  foreach ($k in $extra.Keys) { $b[$k] = $extra[$k] }
  for ($try = 0; $try -lt 3; $try++) {
    try { return (Invoke-WebRequest $Api -Method Post -Body ($b | ConvertTo-Json) -ContentType "application/json" -UseBasicParsing -Headers $Head).Content | ConvertFrom-Json }
    catch { Start-Sleep -Seconds (2 + 3 * $try) }
  }
  return $null
}

# Firestore REST wants typed values
function ToV($v) {
  if ($null -eq $v) { return @{ nullValue = $null } }
  if ($v -is [bool]) { return @{ booleanValue = $v } }
  if ($v -is [int] -or $v -is [long]) { return @{ integerValue = "$v" } }
  if ($v -is [double] -or $v -is [decimal]) { return @{ doubleValue = [double]$v } }
  if ($v -is [string]) { return @{ stringValue = $v } }
  if ($v -is [System.Collections.IDictionary]) { $f = @{}; foreach ($k in $v.Keys) { $f["$k"] = ToV $v[$k] }; return @{ mapValue = @{ fields = $f } } }
  if ($v -is [System.Collections.IEnumerable]) { return @{ arrayValue = @{ values = @($v | ForEach-Object { ToV $_ }) } } }
  return @{ stringValue = "$v" }
}

# Central time, on Windows or Linux
try { $tz = [TimeZoneInfo]::FindSystemTimeZoneById("America/Chicago") } catch { $tz = [TimeZoneInfo]::FindSystemTimeZoneById("Central Standard Time") }
$now = [TimeZoneInfo]::ConvertTime([DateTimeOffset]::UtcNow, $tz)
$today = $now.Date

# Today (if there's still daylight), tomorrow, and the coming weekend
$dates = New-Object System.Collections.Generic.List[datetime]
if ($now.Hour -lt 15) { $dates.Add($today) }
$dates.Add($today.AddDays(1))
for ($i = 1; $i -le 7; $i++) { $d = $today.AddDays($i); if ($d.DayOfWeek -eq "Saturday" -or $d.DayOfWeek -eq "Sunday") { if (-not $dates.Contains($d)) { $dates.Add($d) } } }
$dates = $dates | Sort-Object | Select-Object -First 4

$facs = [ordered]@{}
$days = [ordered]@{}
foreach ($d in $dates) {
  $label = $d.ToString("MMM dd yyyy", [Globalization.CultureInfo]::InvariantCulture)
  $key = $d.ToString("yyyy-MM-dd")
  $day = [ordered]@{}
  # Courses with times that day, a page of 30 at a time
  $ids = @()
  for ($page = 0; $page -lt 4; $page++) {
    $r = Search $label @{ PageNumber = $page }
    $list = @($r.ttResults.facilities)
    foreach ($f in $list) {
      if (-not $f.id) { continue }
      $ids += $f.id
      if (-not $facs.Contains("$($f.id)")) {
        $name = ($f.name -replace '\s+(Golf Club|Golf Course|Golf & Country Club|Golf Country Club|Golf Park)$', '').Trim()
        $facs["$($f.id)"] = [ordered]@{ id = [int]$f.id; n = $name; c = $f.address.city; d = [int][math]::Round($f.distance); r = [math]::Round([double]$f.averageRating, 1); seo = $f.seoFriendlyName; ph = $null }
      }
    }
    if ($list.Count -lt 30) { break }
  }
  foreach ($id in $ids) {
    $r = Search $label @{ SearchType = 1; FacilityId = $id; View = "Grouping" }
    $parts = @()
    foreach ($t in @($r.ttResults.teeTimes)) {
      if (-not $t.time.date) { continue }
      if (-not $facs["$id"].ph -and $t.facility.phoneNumber) { $facs["$id"].ph = $t.facility.phoneNumber }
      $hhmm = $t.time.date.Substring(11, 2) + $t.time.date.Substring(14, 2)
      $price = [double]$t.displayRate.value
      $pl = $Players["$($t.playerRule)"]; if (-not $pl) { $pl = "1234" }
      $s = "$hhmm,$([math]::Round($price, 2)),$pl"
      if ("$($t.multipleHolesRate)" -eq "9") { $s += ",9" }
      $parts += $s
    }
    if ($parts.Count) { $day["$id"] = ($parts | Sort-Object) -join " " }
  }
  $days[$key] = $day
}

$total = ($days.Values | ForEach-Object { $_.Count } | Measure-Object -Sum).Sum
if (-not $total) { Write-Output "No tee times found; leaving the saved list alone."; exit 0 }

$data = [ordered]@{ as_of = $now.ToString("yyyy-MM-ddTHH:mm:sszzz"); facs = @($facs.Values | Sort-Object { $_.d }); days = $days }
$body = @{ fields = (ToV $data).mapValue.fields } | ConvertTo-Json -Depth 30 -Compress
Invoke-WebRequest $Doc -Method Patch -Body ([Text.Encoding]::UTF8.GetBytes($body)) -ContentType "application/json; charset=utf-8" -UseBasicParsing | Out-Null
Write-Output "Saved $total course-days across $($dates.Count) days, as of $($data.as_of)."
