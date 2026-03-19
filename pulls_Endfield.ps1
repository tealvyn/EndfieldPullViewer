[CmdletBinding()]
param(
    [string]$CachePath = "$env:LOCALAPPDATA\PlatformProcess\Cache\data_1",
    [string]$HostName = "ef-webview.gryphline.com",
    [string]$OutDir = "",
    [string]$Lang = "en-us"
)

# определяем корневую папку скрипта надёжно
$ScriptDir = $PSScriptRoot
if (-not $ScriptDir) {
    $ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
}
if (-not $ScriptDir) {
    $ScriptDir = (Get-Location).Path
}

if (-not $OutDir -or $OutDir -match '^[A-Za-z]?\\pulls$') {
    $OutDir = Join-Path $ScriptDir "pulls"
}


$configPath = Join-Path $ScriptDir "config.txt"

if (Test-Path $configPath) {
    $script:SheetsUrl = (Get-Content $configPath -Raw).Trim()
}
else {
    $script:SheetsUrl = ""
}

$ErrorActionPreference = "Stop"

try {
    Add-Type -AssemblyName System.Web
}
catch {
    Write-Host "Error loading System.Web" -ForegroundColor Red
    return
}

$Banners = @(
    @{ PoolType = "E_CharacterGachaPoolType_Standard"; Label = "Standard"; HasPity = $true }
    @{ PoolType = "E_CharacterGachaPoolType_Special"; Label = "Limited"; HasPity = $true }
    @{ PoolType = "E_CharacterGachaPoolType_Beginner"; Label = "Beginner"; HasPity = $true }
)

function Write-Header {
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host "  Endfield Pull Tracker  ->  Sheets     " -ForegroundColor Green
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host ""
}

function Read-CacheContent {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        Write-Host "Could not find data_1 at: $Path" -ForegroundColor Red
        Write-Host "Make sure the game is launched at least once." -ForegroundColor Yellow
        return $null
    }

    Write-Host "Reading cache: $Path" -ForegroundColor Green

    try {
        $stream = [System.IO.File]::Open(
            $Path,
            [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::Read,
            [System.IO.FileShare]::ReadWrite
        )
    }
    catch {
        Write-Host "Cannot open data_1 (locked by another process)." -ForegroundColor Red
        Write-Host "Try running script while in main menu or right after closing the game." -ForegroundColor Yellow
        return $null
    }

    try {
        $bytes = New-Object byte[] $stream.Length
        [void]$stream.Read($bytes, 0, $bytes.Length)
    }
    finally {
        $stream.Close()
    }

    $text = [System.Text.Encoding]::UTF8.GetString($bytes)
    $text = $text -replace '\\u0026', '&'
    $text = $text -replace '\\/', '/'
    $text = $text -replace '&amp;', '&'
    return $text
}


function Get-LatestRecordUrl {
    param([string]$Content, [string]$Domain)

    # Ищем любую http(s) ссылку с параметром u8_token=...
    $pattern = 'https?://[^\s"''<>\\]+u8_token=[^\s"''<>\\]+'

    $urlMatches = [regex]::Matches($Content, $pattern)
    if ($urlMatches.Count -eq 0) { return $null }

    return $urlMatches[$urlMatches.Count - 1].Value
}


function Get-TokenAndServer {
    param([string]$RecordUrl)

    $uri = [Uri]$RecordUrl
    $query = [System.Web.HttpUtility]::ParseQueryString($uri.Query)

    $token = $query["u8_token"]
    if ([string]::IsNullOrWhiteSpace($token)) { throw "Token not found." }

    $serverId = $query["server"]
    if ([string]::IsNullOrWhiteSpace($serverId)) { $serverId = "3" }

    return @{ Token = $token; ServerId = $serverId }
}

function Fetch-AllPulls {
    param(
        [string]$Token,
        [string]$ServerId,
        [string]$PoolType
    )

    $records = [System.Collections.Generic.List[object]]::new()
    $lastSeqId = $null

    do {
        $b = [System.UriBuilder]::new("https", $HostName)
        $b.Path = "/api/record/char"
        $q = [System.Web.HttpUtility]::ParseQueryString("")
        $q["lang"] = $Lang
        $q["pool_type"] = $PoolType
        $q["token"] = $Token
        $q["server_id"] = $ServerId
        if ($null -ne $lastSeqId) { $q["seq_id"] = $lastSeqId }
        $b.Query = $q.ToString()

        try {
            $headers = @{
                "User-Agent"      = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36"
                "Accept"          = "application/json, text/plain, */*"
                "Accept-Language" = "en-US,en;q=0.9"
                "Origin"          = "https://ef-webview.gryphline.com"
                "Referer"         = ("https://ef-webview.gryphline.com/gacha?u8_token=" + [System.Web.HttpUtility]::UrlEncode($Token))
            }

            $resp = Invoke-RestMethod -Uri $b.Uri.AbsoluteUri -Method Get -TimeoutSec 15 -Headers $headers
        }
        catch {
            Write-Host "  Request error: $_" -ForegroundColor Red
            break
        }

        if ($resp.code -ne 0 -or $null -eq $resp.data -or $resp.data.list.Count -eq 0) { break }

        foreach ($item in $resp.data.list) {
            $tsSeconds = [long]([string]$item.gachaTs) / 1000
            $dt = [DateTimeOffset]::FromUnixTimeSeconds($tsSeconds).LocalDateTime.ToString("yyyy-MM-dd HH:mm:ss")

            $records.Add([PSCustomObject]@{
                    SeqID  = [string]$item.seqId
                    Name   = [string]$item.charName
                    Rarity = [int]$item.rarity
                    Time   = $dt
                    Banner = [string]$item.poolName
                    IsFree = [bool]$item.isFree
                })
        }

        $lastSeqId = $resp.data.list[-1].seqId
        Start-Sleep -Milliseconds 350
    } while ($resp.data.list.Count -ge 5)

    return , $records
}

function Fetch-WeaponPools {
    param(
        [string]$Token,
        [string]$ServerId
    )

    $b = [System.UriBuilder]::new("https", $HostName)
    $b.Path = "/api/record/weapon/pool"

    $q = [System.Web.HttpUtility]::ParseQueryString("")
    $q["lang"] = $Lang
    $q["token"] = $Token
    $q["server_id"] = $ServerId
    $b.Query = $q.ToString()

    try {
        $headers = @{
            "User-Agent"      = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36"
            "Accept"          = "application/json, text/plain, */*"
            "Accept-Language" = "en-US,en;q=0.9"
            "Origin"          = "https://ef-webview.gryphline.com"
            "Referer"         = ("https://ef-webview.gryphline.com/gacha?u8_token=" + [System.Web.HttpUtility]::UrlEncode($Token))
        }

        $resp = Invoke-RestMethod -Uri $b.Uri.AbsoluteUri -Method Get -TimeoutSec 15 -Headers $headers
    }
    catch {
        Write-Host "  Weapon pool request error: $_" -ForegroundColor Red
        return @()
    }

    if ($resp.code -ne 0 -or $null -eq $resp.data) { return @() }

    # ожидается массив объектов { poolId, poolName }
    return , $resp.data
}

function Fetch-AllWeapons {
    param(
        [string]$Token,
        [string]$ServerId,
        [object[]]$Pools
    )

    $records = [System.Collections.Generic.List[object]]::new()

    foreach ($pool in $Pools) {
        $poolId = [string]$pool.poolId
        $poolName = [string]$pool.poolName

        if ([string]::IsNullOrWhiteSpace($poolId)) { continue }

        $lastSeqId = $null

        do {
            $b = [System.UriBuilder]::new("https", $HostName)
            $b.Path = "/api/record/weapon"

            $q = [System.Web.HttpUtility]::ParseQueryString("")
            $q["lang"] = $Lang
            $q["pool_id"] = $poolId
            $q["token"] = $Token
            $q["server_id"] = $ServerId
            if ($null -ne $lastSeqId) { $q["seq_id"] = $lastSeqId }
            $b.Query = $q.ToString()

            try {
                $headers = @{
                    "User-Agent"      = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36"
                    "Accept"          = "application/json, text/plain, */*"
                    "Accept-Language" = "en-US,en;q=0.9"
                    "Origin"          = "https://ef-webview.gryphline.com"
                    "Referer"         = ("https://ef-webview.gryphline.com/gacha?u8_token=" + [System.Web.HttpUtility]::UrlEncode($Token))
                }

                $resp = Invoke-RestMethod -Uri $b.Uri.AbsoluteUri -Method Get -TimeoutSec 15 -Headers $headers
            }
            catch {
                Write-Host "  Weapon request error: $_" -ForegroundColor Red
                break
            }

            if ($resp.code -ne 0 -or $null -eq $resp.data -or $resp.data.list.Count -eq 0) { break }

            foreach ($item in $resp.data.list) {
                $tsSeconds = [long]([string]$item.gachaTs) / 1000
                $dt = [DateTimeOffset]::FromUnixTimeSeconds($tsSeconds).LocalDateTime.ToString("yyyy-MM-dd HH:mm:ss")

                $records.Add([PSCustomObject]@{
                        SeqID      = [string]$item.seqId
                        Time       = $dt
                        Name       = [string]$item.weaponName
                        Rarity     = [int]$item.rarity
                        BannerId   = [string]$poolId
                        BannerName = [string]$poolName
                        Type       = "weapon"
                    })
            }

            $lastSeqId = $resp.data.list[-1].seqId
            Start-Sleep -Milliseconds 350
        } while ($resp.data.list.Count -ge 5)
    }

    return , $records
}

function Compute-Pity {
    param(
        [object[]]$Records,
        [bool]$HasPity
    )

    if ($null -eq $Records -or $Records.Count -eq 0) { return , @() }

    $sorted = $Records | Sort-Object @(
        @{ Expression = {
                if ([string]::IsNullOrWhiteSpace($_.Time)) { [datetime]::MinValue }
                else { [datetime]$_.Time }
            }
        },
        @{ Expression = { [long]$_.SeqID } }
    )

    if ($HasPity) {
        $pity = 0
        foreach ($row in $sorted) {
            $free = ($row.IsFree -eq $true -or $row.IsFree -eq "True")
            if ($free) {
                $row | Add-Member -Force -NotePropertyName Pity -NotePropertyValue "-"
            }
            else {
                $pity++
                $row | Add-Member -Force -NotePropertyName Pity -NotePropertyValue $pity
                if ([int]$row.Rarity -ge 6) { $pity = 0 }
            }
        }
    }
    else {
        foreach ($row in $sorted) {
            $row | Add-Member -Force -NotePropertyName Pity -NotePropertyValue "-"
        }
    }

    return , $sorted
}

function Send-Banner {
    param(
        [string]$Label,
        [object[]]$Records
    )


    if ([string]::IsNullOrWhiteSpace($script:SheetsUrl)) {
        Write-Host "  Sheets not configured (no config.txt), skipping." -ForegroundColor Gray
        return
    }

    if ($Records.Count -eq 0) {
        Write-Host "  Nothing to send." -ForegroundColor Gray
        return
    }

    Write-Host "Sending [$Label] ($($Records.Count) records)..." -ForegroundColor Cyan

    $payload = @{}
    $payload[$Label] = @($Records | ForEach-Object {
            @{
                SeqID  = $_.SeqID
                Name   = $_.Name
                Rarity = $_.Rarity
                Time   = $_.Time
                Banner = $_.Banner
                IsFree = if ($_.IsFree -eq $true -or $_.IsFree -eq "True") { "True" } else { "False" }
                Pity   = $_.Pity
            }
        })

    $body = $payload | ConvertTo-Json -Depth 5 -Compress

    try {
        $req = [System.Net.HttpWebRequest]::Create($script:SheetsUrl)
        $req.Method = "POST"
        $req.ContentType = "application/json"
        $req.AllowAutoRedirect = $false

        $bytes = [System.Text.Encoding]::UTF8.GetBytes($body)
        $req.ContentLength = $bytes.Length
        $stream = $req.GetRequestStream()
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Close()

        $httpResp = $null
        try {
            $httpResp = $req.GetResponse()
        }
        catch [System.Net.WebException] {
            $httpResp = $_.Exception.Response
        }

        $redirectUrl = $httpResp.Headers["Location"]
        $httpResp.Close()

        $result = Invoke-RestMethod -Uri $redirectUrl -Method Get -TimeoutSec 60

        if ($result.status -eq "ok") {
            Write-Host "  Added: $($result.added)" -ForegroundColor Green
        }
        else {
            Write-Host "  Error: $($result.message)" -ForegroundColor Red
        }
    }
    catch {
        Write-Host "  Send error: $_" -ForegroundColor Red
    }

    Start-Sleep -Seconds 3
}

# ── Main ─────────────────────────────────────────────────────────────

Write-Header

$content = Read-CacheContent -Path $CachePath
if ($null -eq $content) { Read-Host "Press Enter to exit"; return }

$recordUrl = Get-LatestRecordUrl -Content $content -Domain $HostName
if ([string]::IsNullOrWhiteSpace($recordUrl)) {
    Write-Host "No URL with u8_token found in data_1." -ForegroundColor Red
    Read-Host "Press Enter to exit"; return
}

try { $creds = Get-TokenAndServer -RecordUrl $recordUrl }
catch {
    Write-Host "Token error: $_" -ForegroundColor Red
    Read-Host "Press Enter to exit"; return
}

Write-Host "Server: $($creds.ServerId)  |  Token: $($creds.Token.Substring(0,8))..." -ForegroundColor Gray
Write-Host ""

if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Path $OutDir | Out-Null }

$jsonPath = Join-Path $OutDir "pulls.json"

# Загружаем существующий pulls.json если есть
$existingJson = @{ characters = @(); weapons = @() }
if (Test-Path $jsonPath) {
    try {
        $existingJson = Get-Content $jsonPath -Raw -Encoding UTF8 | ConvertFrom-Json
        # конвертируем в изменяемые списки
        $existingJson = @{
            characters = [System.Collections.Generic.List[object]]($existingJson.characters)
            weapons    = [System.Collections.Generic.List[object]]($existingJson.weapons)
        }
    } catch {
        Write-Host "Could not read existing pulls.json, starting fresh." -ForegroundColor Yellow
        $existingJson = @{
            characters = [System.Collections.Generic.List[object]]::new()
            weapons    = [System.Collections.Generic.List[object]]::new()
        }
    }
} else {
    $existingJson = @{
        characters = [System.Collections.Generic.List[object]]::new()
        weapons    = [System.Collections.Generic.List[object]]::new()
    }
}

# Существующие SeqID персонажей
$existingCharIds = @{}
foreach ($c in $existingJson.characters) { $existingCharIds[[string]$c.seqId] = $true }

# Фетчим персонажей
foreach ($banner in $Banners) {
    Write-Host "[$($banner.Label)]" -ForegroundColor White
    Write-Host "  Fetching..." -ForegroundColor Cyan -NoNewline

    $fetched = Fetch-AllPulls -Token $creds.Token -ServerId $creds.ServerId -PoolType $banner.PoolType
    Write-Host " $($fetched.Count) records." -ForegroundColor Cyan

    $newOnly = @($fetched | Where-Object { -not $existingCharIds[[string]$_.SeqID] })
    Write-Host "  New: $($newOnly.Count)" -ForegroundColor Green

    if ($newOnly.Count -gt 0) {
        # Пересчитываем pity для всех записей этого баннера
        $allForBanner = @($existingJson.characters | Where-Object { $_.bannerId -eq $newOnly[0].Banner }) + $newOnly
        $allWithPity  = Compute-Pity -Records $allForBanner -HasPity $banner.HasPity

        # Обновляем pity в существующих и добавляем новые
        $pityMap = @{}
        foreach ($r in $allWithPity) { $pityMap[[string]$r.SeqID] = $r.Pity }

        foreach ($c in $existingJson.characters) {
            if ($pityMap.ContainsKey([string]$c.seqId)) { $c.pity = $pityMap[[string]$c.seqId] }
        }

        foreach ($r in $newOnly) {
            $existingJson.characters.Add([PSCustomObject]@{
                seqId      = [string]$r.SeqID
                time       = $r.Time
                name       = $r.Name
                rarity     = [int]$r.Rarity
                bannerId   = $r.Banner
                bannerName = $r.Banner
                isFree     = $r.IsFree
                pity       = $pityMap[[string]$r.SeqID]
                type       = "character"
            })
            $existingCharIds[[string]$r.SeqID] = $true
        }

        try { Send-Banner -Label $banner.Label -Records $newOnly }
        catch { Write-Host "  Send failed but continuing..." -ForegroundColor Yellow }
    }

    Write-Host ""
}

# Фетчим оружие
Write-Host "Fetching weapon banners..." -ForegroundColor Cyan
$weaponPools = Fetch-WeaponPools -Token $creds.Token -ServerId $creds.ServerId
Write-Host "  Pools: $($weaponPools.Count)" -ForegroundColor Cyan

if ($weaponPools.Count -gt 0) {
    Write-Host "Fetching weapon history..." -ForegroundColor Cyan
    $allWeapons = Fetch-AllWeapons -Token $creds.Token -ServerId $creds.ServerId -Pools $weaponPools
    Write-Host "  Weapons: $($allWeapons.Count)" -ForegroundColor Cyan

    $existingWeapIds = @{}
    foreach ($w in $existingJson.weapons) { $existingWeapIds[[string]$w.seqId] = $true }

    $newWeapons = @($allWeapons | Where-Object { -not $existingWeapIds[[string]$_.SeqID] })
    Write-Host "  New weapons: $($newWeapons.Count)" -ForegroundColor Green

    if ($newWeapons.Count -gt 0) {
        # Pity по каждому баннеру
        $grouped = $allWeapons | Group-Object BannerId
        $pityMap = @{}
        foreach ($g in $grouped) {
            $pity = 0
            foreach ($w in ($g.Group | Sort-Object Time)) {
                $pity++
                $pityMap[[string]$w.SeqID] = $pity
                if ($w.Rarity -ge 5) { $pity = 0 }
            }
        }

        foreach ($w in $newWeapons) {
            $existingJson.weapons.Add([PSCustomObject]@{
                seqId      = [string]$w.SeqID
                time       = $w.Time
                name       = $w.Name
                rarity     = [int]$w.Rarity
                bannerId   = $w.BannerId
                bannerName = $w.BannerName
                pity       = $pityMap[[string]$w.SeqID]
                type       = "weapon"
            })
        }
    }
}

# Сохраняем pulls.json
$jsonObject = @{
    characters = @($existingJson.characters | Sort-Object { [long]$_.seqId })
    weapons    = @($existingJson.weapons    | Sort-Object { [long]$_.seqId })
}

$json = $jsonObject | ConvertTo-Json -Depth 6
Set-Content -LiteralPath $jsonPath -Value $json -Encoding UTF8

Write-Host "Saved pulls.json ($($existingJson.characters.Count) chars, $($existingJson.weapons.Count) weapons)." -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "All done!" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Cyan

Read-Host "Press Enter to exit"
