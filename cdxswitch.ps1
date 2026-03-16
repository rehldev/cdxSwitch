Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$BackupDir = Join-Path $HOME ".codex-switch-backup"
$SequenceFile = Join-Path $BackupDir "sequence.json"

function Get-CodexHome {
    if ($env:CODEX_HOME) {
        return $env:CODEX_HOME
    }
    return Join-Path $HOME ".codex"
}

function Get-CodexAuthPath {
    return Join-Path (Get-CodexHome) "auth.json"
}

function ConvertTo-NativeObject {
    param([Parameter(ValueFromPipeline = $true)]$Value)

    if ($null -eq $Value) {
        return $null
    }

    if ($Value -is [System.Collections.IDictionary]) {
        $result = @{}
        foreach ($key in $Value.Keys) {
            $result[[string]$key] = ConvertTo-NativeObject $Value[$key]
        }
        return $result
    }

    if ($Value -is [System.Management.Automation.PSCustomObject]) {
        $result = @{}
        foreach ($property in $Value.PSObject.Properties) {
            $result[$property.Name] = ConvertTo-NativeObject $property.Value
        }
        return $result
    }

    if (($Value -is [System.Collections.IEnumerable]) -and -not ($Value -is [string])) {
        $items = @()
        foreach ($item in $Value) {
            $items += ,(ConvertTo-NativeObject $item)
        }
        return $items
    }

    return $Value
}

function New-Utf8NoBomEncoding {
    return New-Object System.Text.UTF8Encoding($false)
}

function Get-NowIso {
    return [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")
}

function Test-JsonFile {
    param([string]$Path)
    try {
        Get-Content -Raw -LiteralPath $Path | ConvertFrom-Json | Out-Null
        return $true
    } catch {
        Write-Host "Error: Invalid JSON in $Path"
        return $false
    }
}

function Read-JsonFile {
    param([string]$Path)
    $raw = Get-Content -Raw -LiteralPath $Path
    return ConvertTo-NativeObject ($raw | ConvertFrom-Json)
}

function Write-JsonFile {
    param(
        [string]$Path,
        $Value
    )

    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }

    $tempPath = "$Path.tmp"
    $json = $Value | ConvertTo-Json -Depth 100
    try {
        $json | ConvertFrom-Json | Out-Null
    } catch {
        throw "Error: Generated invalid JSON"
    }

    [System.IO.File]::WriteAllText($tempPath, $json, (New-Utf8NoBomEncoding))
    Move-Item -LiteralPath $tempPath -Destination $Path -Force
}

function Copy-Value {
    param($Value)
    return ConvertTo-NativeObject $Value
}

function Decode-JwtPayload {
    param([string]$Jwt)
    $parts = $Jwt.Split('.')
    if ($parts.Count -lt 2) { return $null }
    $payload = $parts[1]
    # Add base64 padding
    $pad = 4 - ($payload.Length % 4)
    if ($pad -lt 4) {
        $payload += ('=' * $pad)
    }
    # Replace URL-safe characters
    $payload = $payload.Replace('-', '+').Replace('_', '/')
    $bytes = [Convert]::FromBase64String($payload)
    $json = [System.Text.Encoding]::UTF8.GetString($bytes)
    return ConvertTo-NativeObject ($json | ConvertFrom-Json)
}

function Get-CurrentAccount {
    $authPath = Get-CodexAuthPath
    if (-not (Test-Path -LiteralPath $authPath)) {
        return "none"
    }

    if (-not (Test-JsonFile $authPath)) {
        return "none"
    }

    $auth = Read-JsonFile $authPath
    $authMode = $null
    if ($auth -is [System.Collections.IDictionary] -and $auth.ContainsKey("auth_mode")) {
        $authMode = [string]$auth.auth_mode
    }

    switch ($authMode) {
        { $_ -in "chatgpt", "chatgptAuthTokens" } {
            $email = $null
            if ($auth.ContainsKey("tokens") -and $auth.tokens -is [System.Collections.IDictionary]) {
                $tokens = $auth.tokens
                if ($tokens.ContainsKey("id_token") -and -not [string]::IsNullOrWhiteSpace([string]$tokens.id_token)) {
                    $decoded = Decode-JwtPayload ([string]$tokens.id_token)
                    if ($null -ne $decoded -and $decoded -is [System.Collections.IDictionary] -and $decoded.ContainsKey("email")) {
                        $email = [string]$decoded.email
                    }
                }
            }
            if (-not [string]::IsNullOrWhiteSpace($email)) {
                return $email
            }
            return "none"
        }
        "apikey" {
            $key = $null
            if ($auth.ContainsKey("OPENAI_API_KEY")) {
                $key = [string]$auth.OPENAI_API_KEY
            }
            if (-not [string]::IsNullOrWhiteSpace($key) -and $key.Length -ge 4) {
                return "apikey-$($key.Substring($key.Length - 4))"
            }
            return "none"
        }
        default {
            return "none"
        }
    }
}

function Read-Credentials {
    $authPath = Get-CodexAuthPath
    if (Test-Path -LiteralPath $authPath) {
        return Get-Content -Raw -LiteralPath $authPath
    }
    return ""
}

function Write-Credentials {
    param([string]$Credentials)
    $authPath = Get-CodexAuthPath
    $dir = Split-Path -Parent $authPath
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    [System.IO.File]::WriteAllText($authPath, $Credentials, (New-Utf8NoBomEncoding))
}

function Setup-Directories {
    foreach ($path in @(
        $BackupDir,
        (Join-Path $BackupDir "credentials")
    )) {
        if (-not (Test-Path -LiteralPath $path)) {
            New-Item -ItemType Directory -Path $path -Force | Out-Null
        }
    }
}

function Get-AccountCredentialsPath {
    param(
        [string]$AccountNumber,
        [string]$Email
    )
    return Join-Path $BackupDir "credentials\.codex-auth-$AccountNumber-$Email.json"
}

function Read-AccountCredentials {
    param(
        [string]$AccountNumber,
        [string]$Email
    )
    $path = Get-AccountCredentialsPath $AccountNumber $Email
    if (Test-Path -LiteralPath $path) {
        return Get-Content -Raw -LiteralPath $path
    }
    return ""
}

function Write-AccountCredentials {
    param(
        [string]$AccountNumber,
        [string]$Email,
        [string]$Credentials
    )
    $path = Get-AccountCredentialsPath $AccountNumber $Email
    [System.IO.File]::WriteAllText($path, $Credentials, (New-Utf8NoBomEncoding))
}

function Initialize-SequenceFile {
    if (-not (Test-Path -LiteralPath $SequenceFile)) {
        $initial = @{
            activeAccountNumber = $null
            lastUpdated = Get-NowIso
            sequence = @()
            accounts = @{}
        }
        Write-JsonFile $SequenceFile $initial
    }
}

function Normalize-SequenceData {
    param($Sequence)

    if (-not ($Sequence.accounts -is [System.Collections.IDictionary])) {
        $normalizedAccounts = @{}
        if ($null -ne $Sequence.accounts) {
            foreach ($property in $Sequence.accounts.PSObject.Properties) {
                $normalizedAccounts[[string]$property.Name] = ConvertTo-NativeObject $property.Value
            }
        }
        $Sequence.accounts = $normalizedAccounts
    }

    $sequenceItems = @()
    $rawSequence = $Sequence.sequence
    if (($rawSequence -is [System.Collections.IEnumerable]) -and -not ($rawSequence -is [string])) {
        foreach ($item in $rawSequence) {
            if ($null -ne $item -and "$item" -match '^\d+$') {
                $sequenceItems += [int]$item
            }
        }
    } elseif ($null -ne $rawSequence -and "$rawSequence" -match '^\d+$') {
        $sequenceItems += [int]$rawSequence
    }

    $accountNumbers = @()
    foreach ($key in $Sequence.accounts.Keys) {
        if ("$key" -match '^\d+$') {
            $accountNumbers += [int]$key
        }
    }
    $accountNumbers = @($accountNumbers | Sort-Object -Unique)

    $sequenceSet = @{}
    $normalizedSequence = @()
    foreach ($item in $sequenceItems) {
        if ($accountNumbers -contains $item -and -not $sequenceSet.ContainsKey("$item")) {
            $sequenceSet["$item"] = $true
            $normalizedSequence += $item
        }
    }
    foreach ($item in $accountNumbers) {
        if (-not $sequenceSet.ContainsKey("$item")) {
            $sequenceSet["$item"] = $true
            $normalizedSequence += $item
        }
    }

    $Sequence.sequence = @($normalizedSequence)
    return $Sequence
}

function Read-SequenceFile {
    Initialize-SequenceFile
    $sequence = Read-JsonFile $SequenceFile
    return Normalize-SequenceData $sequence
}

function Write-SequenceFile {
    param($Sequence)
    Write-JsonFile $SequenceFile $Sequence
}

function Get-NextAccountNumber {
    $sequence = Read-SequenceFile
    $max = 0
    foreach ($key in $sequence.accounts.Keys) {
        $num = [int]$key
        if ($num -gt $max) {
            $max = $num
        }
    }
    return [string]($max + 1)
}

function Test-Email {
    param([string]$Email)
    return ($Email -match '^[a-zA-Z0-9._%+\-]+@[a-zA-Z0-9.\-]+\.[a-zA-Z]{2,}$')
}

function Test-AccountIdentifier {
    param([string]$Identifier)
    if ($Identifier -match '^\d+$') { return $true }
    if (Test-Email $Identifier) { return $true }
    if ($Identifier -match '^apikey-') { return $true }
    return $false
}

function Get-OptionalEntryValue {
    param(
        $Entry,
        [string]$Key
    )

    if ($null -eq $Entry) {
        return $null
    }

    if ($Entry -is [System.Collections.IDictionary]) {
        if ($Entry.ContainsKey($Key)) {
            return $Entry[$Key]
        }
        return $null
    }

    $property = $Entry.PSObject.Properties[$Key]
    if ($null -eq $property) {
        return $null
    }
    return $property.Value
}

function Get-ManagedAccountEmail {
    param($Entry)

    $email = Get-OptionalEntryValue -Entry $Entry -Key "email"
    if (-not [string]::IsNullOrWhiteSpace([string]$email)) {
        return [string]$email
    }

    return ""
}

function Test-AccountExists {
    param([string]$Email)
    $sequence = Read-SequenceFile
    foreach ($entry in $sequence.accounts.GetEnumerator()) {
        if ((Get-ManagedAccountEmail $entry.Value) -eq $Email) {
            return $true
        }
    }
    return $false
}

function Get-AccountNumberByEmail {
    param([string]$Email)
    $sequence = Read-SequenceFile
    foreach ($entry in $sequence.accounts.GetEnumerator()) {
        if ((Get-ManagedAccountEmail $entry.Value) -eq $Email) {
            return [string]$entry.Key
        }
    }
    return ""
}

function Resolve-AccountIdentifier {
    param([string]$Identifier)
    if ($Identifier -match '^\d+$') {
        return $Identifier
    }
    return Get-AccountNumberByEmail $Identifier
}

function Test-CodexRunning {
    $process = Get-Process -Name "codex" -ErrorAction SilentlyContinue
    return $null -ne $process
}

function Wait-ForCodexClose {
    if (-not (Test-CodexRunning)) {
        return
    }

    Write-Host "Codex CLI is running. Please close it first."
    Write-Host "Waiting for Codex CLI to close..."
    while (Test-CodexRunning) {
        Start-Sleep -Seconds 1
    }
    Write-Host "Codex CLI closed. Continuing..."
}

function Show-Usage {
    Write-Host "Multi-Account Switcher for Codex CLI (Windows)"
    Write-Host "Usage: cdxswitch [COMMAND]"
    Write-Host ""
    Write-Host "Commands:"
    Write-Host "  --add-account                    Add current account to managed accounts"
    Write-Host "  --remove-account <num|email>    Remove account by number or email"
    Write-Host "  --list                           List all managed accounts"
    Write-Host "  --switch                         Rotate to next account in sequence"
    Write-Host "  --switch-to <num|email>          Switch to specific account number or email"
    Write-Host "  --help                           Show this help message"
}

function Add-AccountCommand {
    Setup-Directories
    Initialize-SequenceFile

    $currentEmail = Get-CurrentAccount
    if ($currentEmail -eq "none") {
        throw "Error: No active Codex account found. Please log in first with 'codex login'."
    }

    if (Test-AccountExists $currentEmail) {
        Write-Host "Account $currentEmail is already managed."
        return
    }

    $accountNumber = Get-NextAccountNumber
    $currentCreds = Read-Credentials

    if ([string]::IsNullOrWhiteSpace($currentCreds)) {
        throw "Error: No credentials found for current account"
    }

    # Get user ID from auth.json (decode JWT to extract chatgpt_user_id)
    $authPath = Get-CodexAuthPath
    $auth = Read-JsonFile $authPath
    $userId = "unknown"
    if ($auth.ContainsKey("tokens") -and $auth.tokens -is [System.Collections.IDictionary]) {
        $tokens = $auth.tokens
        if ($tokens.ContainsKey("id_token") -and -not [string]::IsNullOrWhiteSpace([string]$tokens.id_token)) {
            $decoded = Decode-JwtPayload ([string]$tokens.id_token)
            if ($null -ne $decoded -and $decoded -is [System.Collections.IDictionary]) {
                $authClaim = $null
                if ($decoded.ContainsKey("https://api.openai.com/auth")) {
                    $authClaim = $decoded["https://api.openai.com/auth"]
                }
                if ($null -ne $authClaim -and $authClaim -is [System.Collections.IDictionary] -and $authClaim.ContainsKey("chatgpt_user_id")) {
                    $userId = [string]$authClaim.chatgpt_user_id
                }
            }
        }
        if ($userId -eq "unknown" -and $tokens.ContainsKey("account_id")) {
            $userId = [string]$tokens.account_id
        }
    }

    Write-AccountCredentials $accountNumber $currentEmail $currentCreds

    $sequence = Read-SequenceFile
    $sequence.accounts[$accountNumber] = @{
        email = $currentEmail
        userId = $userId
        added = Get-NowIso
    }
    $sequence.sequence = @($sequence.sequence) + @([int]$accountNumber)
    $sequence.activeAccountNumber = [int]$accountNumber
    $sequence.lastUpdated = Get-NowIso
    Write-SequenceFile $sequence

    Write-Host "Added Account ${accountNumber}: $currentEmail"
}

function List-AccountsCommand {
    if (-not (Test-Path -LiteralPath $SequenceFile)) {
        Write-Host "No accounts are managed yet."
        return
    }

    $sequence = Read-SequenceFile
    Write-SequenceFile $sequence
    $currentEmail = Get-CurrentAccount
    $activeAccountNumber = ""
    if ($currentEmail -ne "none") {
        $activeAccountNumber = Get-AccountNumberByEmail $currentEmail
    }

    Write-Host "Accounts:"
    foreach ($number in $sequence.sequence) {
        $key = [string]$number
        $account = $sequence.accounts[$key]
        $email = Get-ManagedAccountEmail $account
        if ($activeAccountNumber -eq $key) {
            Write-Host "  $key`: $email (active)"
        } else {
            Write-Host "  $key`: $email"
        }
    }
}

function Remove-AccountCommand {
    param([string]$Identifier)

    if ([string]::IsNullOrWhiteSpace($Identifier)) {
        throw "Usage: cdxswitch --remove-account <account_number|email>"
    }
    if (-not (Test-Path -LiteralPath $SequenceFile)) {
        throw "Error: No accounts are managed yet"
    }

    if (-not (Test-AccountIdentifier $Identifier)) {
        throw "Error: Invalid identifier: $Identifier"
    }

    $accountNumber = Resolve-AccountIdentifier $Identifier
    if ([string]::IsNullOrWhiteSpace($accountNumber)) {
        throw "Error: No account found with identifier: $Identifier"
    }

    $sequence = Read-SequenceFile
    if (-not $sequence.accounts.ContainsKey($accountNumber)) {
        throw "Error: Account-$accountNumber does not exist"
    }

    $email = Get-ManagedAccountEmail $sequence.accounts[$accountNumber]
    $confirmation = Read-Host "Are you sure you want to permanently remove Account-$accountNumber ($email)? [y/N]"
    if ($confirmation -notin @("y", "Y")) {
        Write-Host "Cancelled"
        return
    }

    $credPath = Get-AccountCredentialsPath $accountNumber $email
    if (Test-Path -LiteralPath $credPath) {
        Remove-Item -LiteralPath $credPath -Force
    }

    $sequence.accounts.Remove($accountNumber)
    $sequence.sequence = @($sequence.sequence | Where-Object { [string]$_ -ne $accountNumber })
    $sequence.lastUpdated = Get-NowIso
    Write-SequenceFile $sequence
    Write-Host "Account-$accountNumber ($email) has been removed"
}

function Perform-Switch {
    param([string]$TargetAccount)

    $sequence = Read-SequenceFile
    $currentEmail = Get-CurrentAccount
    $currentAccount = Get-AccountNumberByEmail $currentEmail
    if ([string]::IsNullOrWhiteSpace($currentAccount)) {
        throw "Error: Current account '$currentEmail' is not managed. Add it first with --add-account."
    }

    $targetEmail = Get-ManagedAccountEmail $sequence.accounts[$TargetAccount]
    $currentCreds = Read-Credentials

    if ([string]::IsNullOrWhiteSpace($currentCreds)) {
        throw "Error: Unable to read credentials for current account ($currentEmail)"
    }

    Write-AccountCredentials $currentAccount $currentEmail $currentCreds

    $targetCreds = Read-AccountCredentials $TargetAccount $targetEmail
    if ([string]::IsNullOrWhiteSpace($targetCreds)) {
        throw "Error: Missing backup data for Account-$TargetAccount"
    }

    Write-Credentials $targetCreds

    $sequence.activeAccountNumber = [int]$TargetAccount
    $sequence.lastUpdated = Get-NowIso
    Write-SequenceFile $sequence

    Write-Host "Switched to Account-$TargetAccount ($targetEmail)"
    List-AccountsCommand
    Write-Host ""
    Write-Host "Please restart Codex CLI to use the new authentication."
}

function Switch-NextCommand {
    if (-not (Test-Path -LiteralPath $SequenceFile)) {
        throw "Error: No accounts are managed yet"
    }

    $currentEmail = Get-CurrentAccount
    if ($currentEmail -eq "none") {
        throw "Error: No active Codex account found"
    }

    if (-not (Test-AccountExists $currentEmail)) {
        Write-Host "Notice: Active account '$currentEmail' was not managed."
        Add-AccountCommand
        $sequence = Read-SequenceFile
        Write-Host "It has been automatically added as Account-$($sequence.activeAccountNumber)."
        Write-Host "Please run 'cdxswitch --switch' again to switch to the next account."
        return
    }

    Wait-ForCodexClose
    $sequence = Read-SequenceFile
    $activeAccount = Get-AccountNumberByEmail $currentEmail
    $numbers = @($sequence.sequence | ForEach-Object { [string]$_ })
    $currentIndex = [Array]::IndexOf($numbers, $activeAccount)
    if ($currentIndex -lt 0) {
        $currentIndex = 0
    }
    $nextIndex = ($currentIndex + 1) % $numbers.Count
    Perform-Switch $numbers[$nextIndex]
}

function Switch-ToCommand {
    param([string]$Identifier)

    if ([string]::IsNullOrWhiteSpace($Identifier)) {
        throw "Usage: cdxswitch --switch-to <account_number|email>"
    }
    if (-not (Test-Path -LiteralPath $SequenceFile)) {
        throw "Error: No accounts are managed yet"
    }

    if (-not (Test-AccountIdentifier $Identifier)) {
        throw "Error: Invalid identifier: $Identifier"
    }

    $targetAccount = Resolve-AccountIdentifier $Identifier
    if ([string]::IsNullOrWhiteSpace($targetAccount)) {
        throw "Error: No account found with identifier: $Identifier"
    }

    $sequence = Read-SequenceFile
    if (-not $sequence.accounts.ContainsKey($targetAccount)) {
        throw "Error: Account-$targetAccount does not exist"
    }

    Wait-ForCodexClose
    Perform-Switch $targetAccount
}

try {
    switch ($args[0]) {
        "--add-account" { Add-AccountCommand; break }
        "--remove-account" { Remove-AccountCommand $args[1]; break }
        "--list" { List-AccountsCommand; break }
        "--switch" { Switch-NextCommand; break }
        "--switch-to" { Switch-ToCommand $args[1]; break }
        "--help" { Show-Usage; break }
        "" { Show-Usage; break }
        $null { Show-Usage; break }
        default {
            throw "Error: Unknown command '$($args[0])'"
        }
    }
} catch {
    Write-Host $_.Exception.Message
    if ($args[0] -ne "--help" -and $args[0] -ne "" -and $null -ne $args[0]) {
        Write-Host ""
        Show-Usage
    }
    exit 1
}
