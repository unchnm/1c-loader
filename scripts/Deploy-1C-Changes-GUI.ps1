#Requires -Version 5.1
# GUI для загрузки изменённых XML/BSL-файлов в базу 1С

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

# Кириллица в выводе внешних команд (git и др.)
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
[Console]::InputEncoding  = [System.Text.Encoding]::UTF8

# Современный диалог выбора папки (IFileOpenDialog, Windows Vista+)
Add-Type @'
using System;
using System.Runtime.InteropServices;

public static class ModernFolderPicker {
    [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
    static extern int SHCreateItemFromParsingName(string path, IntPtr pbc, ref Guid riid, out IShellItem ppv);

    const uint FOS_PICKFOLDERS     = 0x00000020;
    const uint FOS_FORCEFILESYSTEM = 0x00000040;
    const uint FOS_NOCHANGEDIR     = 0x00000008;

    public static string Show(IntPtr owner, string initialPath) {
        var dlg = (IFileOpenDialog)new FileOpenDialogClass();
        try {
            uint opts;
            dlg.GetOptions(out opts);
            dlg.SetOptions(opts | FOS_PICKFOLDERS | FOS_FORCEFILESYSTEM | FOS_NOCHANGEDIR);
            dlg.SetTitle("Выберите папку проекта");
            dlg.SetOkButtonLabel("Выбрать");
            if (!string.IsNullOrEmpty(initialPath)) {
                var iid = typeof(IShellItem).GUID;
                IShellItem folder;
                if (SHCreateItemFromParsingName(initialPath, IntPtr.Zero, ref iid, out folder) >= 0)
                    dlg.SetFolder(folder);
            }
            if (dlg.Show(owner) != 0) return null;
            IShellItem result;
            dlg.GetResult(out result);
            string path;
            result.GetDisplayName(0x80058000u, out path);
            return path;
        } finally {
            Marshal.ReleaseComObject(dlg);
        }
    }

    [ComImport, Guid("DC1C5A9C-E88A-4dde-A5A1-60F82A20AEF7"), ClassInterface(ClassInterfaceType.None)]
    class FileOpenDialogClass {}

    [ComImport, Guid("42F85136-DB7E-439C-85F1-E4075D135FC8"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IFileOpenDialog {
        [PreserveSig] int Show([In] IntPtr hwnd);
        void SetFileTypes([In] uint c, [In] IntPtr p);
        void SetFileTypeIndex([In] uint i);
        void GetFileTypeIndex(out uint i);
        void Advise([In] IntPtr p, out uint c);
        void Unadvise([In] uint c);
        void SetOptions([In] uint fos);
        void GetOptions(out uint fos);
        void SetDefaultFolder([In, MarshalAs(UnmanagedType.Interface)] IShellItem psi);
        void SetFolder([In, MarshalAs(UnmanagedType.Interface)] IShellItem psi);
        void GetFolder([MarshalAs(UnmanagedType.Interface)] out IShellItem ppsi);
        void GetCurrentSelection([MarshalAs(UnmanagedType.Interface)] out IShellItem ppsi);
        void SetFileName([In, MarshalAs(UnmanagedType.LPWStr)] string n);
        void GetFileName([MarshalAs(UnmanagedType.LPWStr)] out string n);
        void SetTitle([In, MarshalAs(UnmanagedType.LPWStr)] string t);
        void SetOkButtonLabel([In, MarshalAs(UnmanagedType.LPWStr)] string t);
        void SetFileNameLabel([In, MarshalAs(UnmanagedType.LPWStr)] string t);
        void GetResult([MarshalAs(UnmanagedType.Interface)] out IShellItem ppsi);
        void AddPlace([In, MarshalAs(UnmanagedType.Interface)] IShellItem psi, [In] int f);
        void SetDefaultExtension([In, MarshalAs(UnmanagedType.LPWStr)] string e);
        void Close([MarshalAs(UnmanagedType.Error)] int hr);
        void SetClientGuid([In] ref Guid g);
        void ClearClientData();
        void SetFilter([In] IntPtr p);
        void GetResults([MarshalAs(UnmanagedType.Interface)] out IntPtr p);
        void GetSelectedItems([MarshalAs(UnmanagedType.Interface)] out IntPtr p);
    }

    [ComImport, Guid("43826D1E-E718-42EE-BC55-A1E261C37BFE"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IShellItem {
        void BindToHandler([In] IntPtr pbc, [In] ref Guid bhid, [In] ref Guid riid, out IntPtr ppv);
        void GetParent([MarshalAs(UnmanagedType.Interface)] out IShellItem ppsi);
        void GetDisplayName([In] uint sigdn, [MarshalAs(UnmanagedType.LPWStr)] out string name);
        void GetAttributes([In] uint mask, out uint attribs);
        void Compare([In, MarshalAs(UnmanagedType.Interface)] IShellItem psi, [In] uint hint, out int order);
    }
}
'@

Add-Type @'
using System;
using System.Runtime.InteropServices;

public static class NativeTheme {
    [DllImport("dwmapi.dll")]
    static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int attrValue, int attrSize);

    [DllImport("uxtheme.dll", CharSet = CharSet.Unicode)]
    static extern int SetWindowTheme(IntPtr hwnd, string pszSubAppName, string pszSubIdList);

    public static void Apply(IntPtr hwnd, bool dark) {
        if (hwnd == IntPtr.Zero) return;
        int flag = dark ? 1 : 0;
        DwmSetWindowAttribute(hwnd, 20, ref flag, 4);
        SetWindowTheme(hwnd, dark ? "DarkMode_Explorer" : null, null);
    }

    public static void SetTheme(IntPtr hwnd, string subAppName) {
        if (hwnd == IntPtr.Zero) return;
        SetWindowTheme(hwnd, subAppName, null);
    }
}
'@

# ─────────────────────────────────────────────────────────────────────────────
# Функции логики (перенесены из Deploy-1C-Changes.ps1)
# ─────────────────────────────────────────────────────────────────────────────

function Test-GitInstalled {
    try { $null = & git --version 2>&1; return ($LASTEXITCODE -eq 0) }
    catch { return $false }
}

function Find-GitRoot {
    param([string]$StartPath)
    $cur = $StartPath
    while ($cur) {
        if (Test-Path (Join-Path $cur '.git')) { return $cur }
        $parent = Split-Path $cur -Parent
        if ($parent -eq $cur) { break }
        $cur = $parent
    }
    return $null
}

function Get-GitChangedFiles {
    param([string]$GitRoot, [string]$SubPath = '')
    Push-Location $GitRoot
    try {
        $unstaged = & git -c core.quotepath=false diff HEAD --name-only --diff-filter=ACMR 2>&1
        if ($LASTEXITCODE -ne 0) { throw ('git diff error: ' + ($unstaged -join ' ')) }
        $staged = @(& git -c core.quotepath=false diff --cached --name-only --diff-filter=ACMR 2>&1)
        if ($LASTEXITCODE -ne 0) { $staged = @() }
        # Новые (неотслеживаемые) файлы
        $untracked = @(& git -c core.quotepath=false ls-files --others --exclude-standard 2>&1)
        if ($LASTEXITCODE -ne 0) { $untracked = @() }

        [string[]]$all = @(
            (@($unstaged) + $staged + $untracked) |
                Where-Object { $_ -and $_ -match '\.(xml|bsl)$' } |
                ForEach-Object { $_.Replace('\', '/').Trim() } |
                Where-Object { $_ } |
                Sort-Object -Unique
        )
        if ($SubPath) {
            $prefix = $SubPath.Replace('\', '/').TrimEnd('/') + '/'
            [string[]]$all = @($all | Where-Object { $_ -and $_.StartsWith($prefix) })
        }
        return $all
    } finally { Pop-Location }
}

function Find-OnecXmlRoot {
    param([string]$StartPath)
    if (Test-Path (Join-Path $StartPath 'Configuration.xml')) { return $StartPath }
    foreach ($sub in @('src', 'src\cf', 'cf', 'config', '1c', 'src\1c', '1c\cf')) {
        $c = Join-Path $StartPath $sub
        if (Test-Path (Join-Path $c 'Configuration.xml')) { return $c }
    }
    foreach ($dir in (Get-ChildItem $StartPath -Directory -ErrorAction SilentlyContinue)) {
        if (Test-Path (Join-Path $dir.FullName 'Configuration.xml')) { return $dir.FullName }
    }
    return $null
}

function Get-BasePlatformVersion {
    param([pscustomobject]$Base)
    if ($Base.DefaultVersion) { return $Base.DefaultVersion.Trim() }
    if ($Base.Version) { return $Base.Version.Trim() }
    return $null
}

function ConvertTo-VersionComparable {
    param([string]$VersionString)
    if (-not $VersionString) { return $null }
    $parts = $VersionString.Trim() -split '\.'
    if ($parts.Count -lt 2) { return $null }
    try {
        while ($parts.Count -lt 4) { $parts += '0' }
        return [version]::new([int]$parts[0], [int]$parts[1], [int]$parts[2], [int]$parts[3])
    } catch {
        return $null
    }
}

function Test-VersionPrefixMatch {
    param([string]$Installed, [string]$Required)
    $reqParts  = $Required.Trim().TrimEnd('.') -split '\.'
    $instParts = $Installed.Trim() -split '\.'
    if ($instParts.Count -lt $reqParts.Count) { return $false }
    for ($i = 0; $i -lt $reqParts.Count; $i++) {
        if ($instParts[$i] -ne $reqParts[$i]) { return $false }
    }
    return $true
}

function Get-Installed1CPlatforms {
    $found = @{}
    foreach ($rp in @('HKLM:\SOFTWARE\1C\1Cv8', 'HKLM:\SOFTWARE\WOW6432Node\1C\1Cv8')) {
        if (-not (Test-Path $rp)) { continue }
        foreach ($v in (Get-ChildItem $rp -ErrorAction SilentlyContinue)) {
            try {
                $loc = (Get-ItemProperty $v.PSPath -ErrorAction Stop).InstallLocation
                if ($loc) {
                    $e = Join-Path $loc 'bin\1cv8.exe'
                    if (Test-Path $e) { $found[$v.Name] = $e }
                }
            } catch { continue }
        }
    }
    foreach ($root in @('C:\Program Files\1cv8', 'C:\Program Files (x86)\1cv8')) {
        if (-not (Test-Path $root)) { continue }
        foreach ($v in (Get-ChildItem $root -Directory -ErrorAction SilentlyContinue)) {
            $e = Join-Path $v.FullName 'bin\1cv8.exe'
            if (Test-Path $e) { $found[$v.Name] = $e }
        }
    }
    return @(
        $found.GetEnumerator() | ForEach-Object {
            $vObj = ConvertTo-VersionComparable $_.Key
            if ($vObj) {
                [pscustomobject]@{ Version = $_.Key; Path = $_.Value; VersionObj = $vObj }
            }
        } | Sort-Object VersionObj -Descending
    )
}

function Find-1CExecutable {
    param([string]$RequiredVersion = '')

    $platforms = @(Get-Installed1CPlatforms)
    if ($platforms.Count -eq 0) {
        return [pscustomobject]@{
            Path           = $null
            MatchedVersion = $null
            UsedFallback   = $false
            Warning        = $null
        }
    }

    if (-not $RequiredVersion) {
        $best = $platforms[0]
        return [pscustomobject]@{
            Path           = $best.Path
            MatchedVersion = $best.Version
            UsedFallback   = $true
            Warning        = 'Версия платформы для базы не указана в ibases.v8i — используется новейшая установленная.'
        }
    }

    $req = $RequiredVersion.Trim()

    $exact = $platforms | Where-Object { $_.Version -eq $req } | Select-Object -First 1
    if ($exact) {
        return [pscustomobject]@{
            Path           = $exact.Path
            MatchedVersion = $exact.Version
            UsedFallback   = $false
            Warning        = $null
        }
    }

    $candidates = @($platforms | Where-Object {
        (Test-VersionPrefixMatch -Installed $_.Version -Required $req) -and ($_.Version -ne $req)
    })
    if ($candidates.Count -gt 0) {
        $best = $candidates[0]
        return [pscustomobject]@{
            Path           = $best.Path
            MatchedVersion = $best.Version
            UsedFallback   = $true
            Warning        = "Точная версия $req не найдена — используется $($best.Version)"
        }
    }

    $newest = $platforms[0]
    return [pscustomobject]@{
        Path           = $newest.Path
        MatchedVersion = $newest.Version
        UsedFallback   = $true
        Warning        = "Версия $req не установлена — используется $($newest.Version)"
    }
}

function Get-IBasesList {
    $p = Join-Path $env:APPDATA '1C\1CEStart\ibases.v8i'
    if (-not (Test-Path $p)) { return $null }
    $content = $null
    foreach ($enc in @([System.Text.Encoding]::UTF8, [System.Text.Encoding]::Unicode, [System.Text.Encoding]::Default)) {
        try {
            $raw = [System.IO.File]::ReadAllText($p, $enc)
            if ($raw -match '(?m)^\[') { $content = $raw -split '\r?\n'; break }
        } catch { continue }
    }
    if (-not $content) { return $null }

    $list = [System.Collections.Generic.List[pscustomobject]]::new()
    $cur  = $null
    foreach ($line in $content) {
        $line = $line.Trim(); if (-not $line) { continue }
        if ($line -match '^\[(.+)\]$') {
            if ($cur) { $list.Add($cur) }
            $cur = [pscustomobject]@{
                Name = $Matches[1].Trim(); Server = ''; Ref = ''; FilePath = ''
                IsServer = $false; Version = ''; DefaultVersion = ''
            }
        } elseif ($cur) {
            if ($line -match '^Connect\s*=\s*(.+)$') {
                $conn = $Matches[1].TrimEnd(';')
                if ($conn -match 'Srvr\s*=\s*"([^"]*)"') { $cur.Server = $Matches[1]; $cur.IsServer = $true }
                if ($conn -match 'Ref\s*=\s*"([^"]*)"')  { $cur.Ref    = $Matches[1] }
                if ($conn -match 'File\s*=\s*"([^"]*)"') { $cur.FilePath = $Matches[1] }
            } elseif ($line -match '^Version\s*=\s*(.+)$') {
                $cur.Version = $Matches[1].Trim()
            } elseif ($line -match '^DefaultVersion\s*=\s*(.+)$') {
                $cur.DefaultVersion = $Matches[1].Trim()
            }
        }
    }
    if ($cur) { $list.Add($cur) }
    return @($list | Where-Object { $_.Server -or $_.FilePath })
}

function Update-BasesComboBox {
    $prevName = $null
    if ($script:bases -and $cmbBase.SelectedIndex -ge 0 -and $cmbBase.SelectedIndex -lt $script:bases.Count) {
        $prevName = $script:bases[$cmbBase.SelectedIndex].Name
    }

    $cmbBase.Items.Clear()
    $allBases = Get-IBasesList
    if ($allBases -and $allBases.Count -gt 0) {
        $script:bases = $allBases
        $cmbBase.Enabled = $true
        $sel = 0
        for ($i = 0; $i -lt $allBases.Count; $i++) {
            $b = $allBases[$i]
            $label = if ($b.IsServer) {
                "$($b.Name)   [$($b.Server) / $($b.Ref)]"
            } else {
                "$($b.Name)   [$($b.FilePath)]"
            }
            [void]$cmbBase.Items.Add($label)
            if ($prevName -and $b.Name -eq $prevName) { $sel = $i }
        }
        $cmbBase.SelectedIndex = $sel
    } else {
        $script:bases = @()
        [void]$cmbBase.Items.Add('Базы не найдены — запустите 1С:Предприятие и добавьте базы')
        $cmbBase.Enabled = $false
    }
}

function Write-TempDevBase {
    param([string]$ProjectRoot, [pscustomobject]$Database, [string]$OnecExePath)
    $dp  = Join-Path $ProjectRoot '.1c-devbase.bat'
    $bp  = Join-Path $ProjectRoot '.1c-devbase.bat.bak'
    $had = Test-Path $dp
    if ($had) { Copy-Item $dp $bp -Force }
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add('@echo off')
    $lines.Add("set `"ONEC_PATH=$OnecExePath`"")
    if ($Database.IsServer) {
        $lines.Add("set `"ONEC_SERVER=$($Database.Server)`"")
        $lines.Add("set `"ONEC_BASE=$($Database.Ref)`"")
    } else {
        $lines.Add("set `"ONEC_FILEBASE_PATH=$($Database.FilePath)`"")
    }
    [System.IO.File]::WriteAllLines($dp, $lines, [System.Text.Encoding]::ASCII)
    return [pscustomobject]@{ DevBasePath = $dp; BackupPath = $bp; HadOriginal = $had }
}

function Restore-DevBase {
    param([pscustomobject]$State)
    try {
        if ($State.HadOriginal -and (Test-Path $State.BackupPath)) {
            Copy-Item $State.BackupPath $State.DevBasePath -Force
            Remove-Item $State.BackupPath -Force -ErrorAction SilentlyContinue
        } elseif (-not $State.HadOriginal -and (Test-Path $State.DevBasePath)) {
            Remove-Item $State.DevBasePath -Force -ErrorAction SilentlyContinue
        }
    } catch { }
}

function Start-1CLoad {
    param([string]$WorkingDirectory, [string]$XmlDir, [string[]]$RelFiles, [switch]$SkipDbUpdate)

    # Ищем load-config.bat: сначала в папке скрипта, затем в Cursor-скиллах
    $localScript  = Join-Path $PSScriptRoot 'load-config.bat'
    $cursorScript = Join-Path $HOME '.cursor\skills\1c-batch\scripts\load-config.bat'
    if     (Test-Path $localScript)  { $skillScript = $localScript }
    elseif (Test-Path $cursorScript) { $skillScript = $cursorScript }
    else   { throw "load-config.bat не найден ни в $PSScriptRoot, ни в $cursorScript" }

    $fileList = ($RelFiles | ForEach-Object { $_.Replace('/', '\') }) -join ','
    $batArgs  = "`"$XmlDir`""
    if ($fileList)     { $batArgs += " `"$fileList`"" }
    if ($SkipDbUpdate) { $batArgs += ' skipdbupdate' }
    $cmdLine = "/c `"`"$skillScript`" $batArgs`""
    return Start-Process 'cmd.exe' -ArgumentList $cmdLine -WorkingDirectory $WorkingDirectory -WindowStyle Hidden -PassThru
}

function Open-1CConfigurator {
    # Открывает конфигуратор 1С для выбранной базы
    param([string]$OnecExePath, [pscustomobject]$Database)
    if ($Database.IsServer) {
        $connArg = "/S `"$($Database.Server)\$($Database.Ref)`""
    } else {
        $connArg = "/F `"$($Database.FilePath)`""
    }
    Start-Process $OnecExePath -ArgumentList "DESIGNER $connArg"
}

# ─────────────────────────────────────────────────────────────────────────────
# Состояние приложения (script-scope — доступно из всех обработчиков)
# ─────────────────────────────────────────────────────────────────────────────
$script:bases         = @()
$script:gitRoot       = $null
$script:xmlDir        = $null
$script:subPathFilter = ''
$script:devbaseState  = $null
$script:loadProc      = $null
$script:loadTicks     = 0
$script:loadingBase   = $null
$script:loadingOnecExe = $null
$script:uiTheme       = 'Light'
$script:labelTone     = @{
    lblFound  = 'Muted'
    lblStatus = 'Muted'
}

function Get-UiThemeFilePath {
    return (Join-Path $env:LOCALAPPDATA '1c-loader\ui-theme.txt')
}

function Read-SavedUiTheme {
    try {
        $path = Get-UiThemeFilePath
        if (-not (Test-Path -LiteralPath $path)) { return 'Light' }
        $value = (Get-Content -LiteralPath $path -Raw -ErrorAction Stop).Trim()
        if ($value -eq 'Dark') { return 'Dark' }
    } catch {}
    return 'Light'
}

function Save-UiTheme {
    param([ValidateSet('Light', 'Dark')][string]$Name)
    try {
        $path = Get-UiThemeFilePath
        $dir  = Split-Path -Parent $path
        if (-not (Test-Path -LiteralPath $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }
        Set-Content -LiteralPath $path -Value $Name -Encoding ascii -NoNewline
    } catch {}
}

function Get-UiOptionsFilePath {
    return (Join-Path $env:LOCALAPPDATA '1c-loader\ui-options.txt')
}

function Read-SavedUiOptions {
    $options = @{ OpenConf = $false; SkipDbUpdate = $false }
    try {
        $path = Get-UiOptionsFilePath
        if (-not (Test-Path -LiteralPath $path)) { return $options }
        foreach ($line in @(Get-Content -LiteralPath $path -ErrorAction Stop)) {
            if ($line -match '^OpenConf=([01])$') { $options.OpenConf = ($Matches[1] -eq '1') }
            elseif ($line -match '^SkipDbUpdate=([01])$') { $options.SkipDbUpdate = ($Matches[1] -eq '1') }
        }
    } catch {}
    return $options
}

function Save-UiOptions {
    try {
        $path = Get-UiOptionsFilePath
        $dir  = Split-Path -Parent $path
        if (-not (Test-Path -LiteralPath $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }
        $open = if ($chkOpenConf.Checked) { '1' } else { '0' }
        $skip = if ($chkSkipDbUpdate.Checked) { '1' } else { '0' }
        Set-Content -LiteralPath $path -Encoding ascii -Value @("OpenConf=$open", "SkipDbUpdate=$skip")
    } catch {}
}

function Get-UiPalette {
    param([ValidateSet('Light', 'Dark')][string]$Name)
    if ($Name -eq 'Dark') {
        return @{
            FormBack             = [System.Drawing.Color]::FromArgb(30, 30, 30)
            Fore                 = [System.Drawing.Color]::FromArgb(220, 220, 220)
            InputBack            = [System.Drawing.Color]::FromArgb(37, 37, 38)
            Separator            = [System.Drawing.Color]::FromArgb(60, 60, 60)
            Accent               = [System.Drawing.Color]::FromArgb(0, 120, 215)
            AccentFore           = [System.Drawing.Color]::White
            ButtonBack           = [System.Drawing.Color]::FromArgb(62, 62, 66)
            ButtonFore           = [System.Drawing.Color]::FromArgb(220, 220, 220)
            ButtonBorder         = [System.Drawing.Color]::FromArgb(90, 90, 90)
            ButtonHover          = [System.Drawing.Color]::FromArgb(80, 80, 84)
            ButtonBackDisabled   = [System.Drawing.Color]::FromArgb(45, 45, 48)
            ButtonForeDisabled   = [System.Drawing.Color]::FromArgb(110, 110, 110)
            ButtonBorderDisabled = [System.Drawing.Color]::FromArgb(60, 60, 60)
            Muted                = [System.Drawing.Color]::FromArgb(160, 160, 160)
            Success              = [System.Drawing.Color]::FromArgb(106, 190, 120)
            Error                = [System.Drawing.Color]::FromArgb(244, 135, 113)
            Progress             = [System.Drawing.Color]::FromArgb(86, 156, 214)
        }
    }
    return @{
        FormBack   = [System.Drawing.Color]::White
        Fore       = [System.Drawing.SystemColors]::ControlText
        InputBack  = [System.Drawing.Color]::White
        Separator  = [System.Drawing.Color]::FromArgb(220, 220, 220)
        Accent     = [System.Drawing.Color]::FromArgb(0, 120, 215)
        AccentFore = [System.Drawing.Color]::White
        Muted      = [System.Drawing.Color]::Gray
        Success    = [System.Drawing.Color]::FromArgb(0, 128, 0)
        Error      = [System.Drawing.Color]::Red
        Progress   = [System.Drawing.Color]::FromArgb(0, 102, 204)
    }
}

function Set-LabelTone {
    param(
        [Parameter(Mandatory)][System.Windows.Forms.Label]$Label,
        [Parameter(Mandatory)][ValidateSet('Muted', 'Success', 'Error', 'Progress')][string]$Tone
    )
    $script:labelTone[$Label.Name] = $Tone
    $Label.ForeColor = (Get-UiPalette -Name $script:uiTheme)[$Tone]
}

function Update-SecondaryButton {
    param(
        $Button,
        $Palette,
        [bool]$Dark
    )
    if (-not $Dark) {
        $Button.UseVisualStyleBackColor = $true
        $Button.FlatStyle = 'System'
        $Button.ForeColor = [System.Drawing.SystemColors]::ControlText
        $Button.BackColor = [System.Drawing.SystemColors]::Control
        return
    }

    $Button.FlatStyle = 'Flat'
    $Button.UseVisualStyleBackColor = $false
    $Button.FlatAppearance.BorderSize = 1
    if ($Button.Enabled) {
        $Button.BackColor = $Palette.ButtonBack
        $Button.ForeColor = $Palette.ButtonFore
        $Button.FlatAppearance.BorderColor = $Palette.ButtonBorder
        $Button.FlatAppearance.MouseOverBackColor = $Palette.ButtonHover
        $Button.FlatAppearance.MouseDownBackColor = $Palette.ButtonHover
    } else {
        $Button.BackColor = $Palette.ButtonBackDisabled
        $Button.ForeColor = $Palette.ButtonForeDisabled
        $Button.FlatAppearance.BorderColor = $Palette.ButtonBorderDisabled
    }
}

function Update-LoadButton {
    param($Palette, [bool]$Dark)
    if ($Dark) {
        Update-SecondaryButton -Button $btnLoad -Palette $Palette -Dark $true
        return
    }
    $btnLoad.FlatStyle = 'Flat'
    $btnLoad.UseVisualStyleBackColor = $false
    $btnLoad.BackColor = $Palette.Accent
    $btnLoad.ForeColor = $Palette.AccentFore
    $btnLoad.FlatAppearance.BorderSize = 0
    $btnLoad.FlatAppearance.MouseOverBackColor = [System.Drawing.Color]::Empty
    $btnLoad.FlatAppearance.MouseDownBackColor = [System.Drawing.Color]::Empty
}

function Update-SecondaryButtonsForEnabledState {
    if ($script:uiTheme -ne 'Dark') { return }
    $palette = Get-UiPalette -Name 'Dark'
    foreach ($btn in @($btnBrowse, $btnRefreshBases, $btnRead)) {
        Update-SecondaryButton -Button $btn -Palette $palette -Dark $true
    }
    Update-LoadButton -Palette $palette -Dark $true
}

function Update-NativeUiTheme {
    $dark = ($script:uiTheme -eq 'Dark')
    try { [NativeTheme]::Apply($form.Handle, $dark) } catch {}
    try {
        if ($form.Visible -and $checkedList.IsHandleCreated) {
            $flags = [System.Reflection.BindingFlags]::Instance -bor [System.Reflection.BindingFlags]::NonPublic
            $method = $checkedList.GetType().GetMethod('RecreateHandle', $flags)
            if ($method) { [void]$method.Invoke($checkedList, $null) }
        }
        [NativeTheme]::Apply($checkedList.Handle, $dark)
    } catch {}
    try {
        if ($null -ne $settingsForm -and $settingsForm.IsHandleCreated) {
            [NativeTheme]::Apply($settingsForm.Handle, $dark)
        }
    } catch {}
}

function Set-UiTheme {
    param([ValidateSet('Light', 'Dark')][string]$Name)
    $script:uiTheme = $Name
    $palette = Get-UiPalette -Name $Name
    $isDark  = ($Name -eq 'Dark')

    $form.BackColor = $palette.FormBack
    $form.ForeColor = $palette.Fore

    $txtPath.BackColor   = $palette.InputBack
    $txtPath.ForeColor   = $palette.Fore
    $txtPath.BorderStyle = if ($isDark) { 'FixedSingle' } else { 'Fixed3D' }

    $comboStyle = if ($isDark) { [System.Windows.Forms.FlatStyle]::Standard } else { [System.Windows.Forms.FlatStyle]::System }
    if ($cmbBase.FlatStyle -ne $comboStyle) { $cmbBase.FlatStyle = $comboStyle }
    $cmbBase.BackColor = $palette.InputBack
    $cmbBase.ForeColor = $palette.Fore
    try { [NativeTheme]::SetTheme($cmbBase.Handle, $(if ($isDark) { 'DarkMode_CFD' } else { $null })) } catch {}
    $cmbBase.Invalidate()

    $checkedList.BackColor = $palette.InputBack
    $checkedList.ForeColor = $palette.Fore

    $sep.BackColor = $palette.Separator

    Update-LoadButton -Palette $palette -Dark $isDark

    foreach ($btn in @($btnBrowse, $btnRefreshBases, $btnRead, $btnTheme)) {
        Update-SecondaryButton -Button $btn -Palette $palette -Dark $isDark
    }
    if ($null -ne $btnTheme) {
        $btnTheme.Text = if ($isDark) { 'Светлая тема' } else { 'Тёмная тема' }
    }
    if ($null -ne $settingsForm) {
        $settingsForm.BackColor = $palette.FormBack
        $settingsForm.ForeColor = $palette.Fore
    }

    foreach ($chk in @($chkSelectAll, $chkDeselectAll, $chkOpenConf, $chkSkipDbUpdate)) {
        $chk.UseVisualStyleBackColor = -not $isDark
        $chk.BackColor = $palette.FormBack
        $chk.ForeColor = $palette.Fore
        if ($isDark) {
            $chk.FlatStyle = 'Flat'
            $chk.FlatAppearance.BorderColor = $palette.ButtonBorder
            $chk.FlatAppearance.CheckedBackColor = $palette.ButtonBack
            $chk.FlatAppearance.MouseOverBackColor = $palette.ButtonHover
            $chk.FlatAppearance.MouseDownBackColor = $palette.ButtonHover
        } else {
            $chk.FlatStyle = 'Standard'
        }
    }

    foreach ($key in @($script:labelTone.Keys)) {
        $label = $form.Controls.Find($key, $false) | Select-Object -First 1
        if ($null -ne $label) { $label.ForeColor = $palette[$script:labelTone[$key]] }
    }

    Update-NativeUiTheme
    if ($form.IsHandleCreated) { $form.Refresh() }
}

# ─────────────────────────────────────────────────────────────────────────────
# Форма
# ─────────────────────────────────────────────────────────────────────────────
$form                  = New-Object System.Windows.Forms.Form
$form.Text             = '1С: Загрузка изменённых файлов'
$form.ClientSize       = New-Object System.Drawing.Size(660, 500)
$form.FormBorderStyle  = 'FixedSingle'
$form.MaximizeBox      = $false
$form.StartPosition    = 'CenterScreen'
$form.Font             = New-Object System.Drawing.Font('Segoe UI', 9)
$form.BackColor        = [System.Drawing.Color]::White

# ── Папка проекта ─────────────────────────────────────────────────────────────
$lblSettings            = New-Object System.Windows.Forms.Label
$lblSettings.Text       = 'Настройки'
$lblSettings.AutoSize   = $true
$lblSettings.Cursor     = [System.Windows.Forms.Cursors]::Hand
$lblSettings.Location   = New-Object System.Drawing.Point(12, 8)

$lblPath           = New-Object System.Windows.Forms.Label
$lblPath.Text      = 'Папка проекта:'
$lblPath.AutoSize  = $true
$lblPath.Location  = New-Object System.Drawing.Point(12, 14)

$txtPath           = New-Object System.Windows.Forms.TextBox
$txtPath.Location  = New-Object System.Drawing.Point(12, 34)
$txtPath.Size      = New-Object System.Drawing.Size(518, 24)

$btnBrowse          = New-Object System.Windows.Forms.Button
$btnBrowse.Text     = 'Обзор...'
$btnBrowse.Location = New-Object System.Drawing.Point(538, 32)
$btnBrowse.Size     = New-Object System.Drawing.Size(110, 28)
$btnBrowse.FlatStyle = 'System'

# ── База 1С ───────────────────────────────────────────────────────────────────
$lblBase           = New-Object System.Windows.Forms.Label
$lblBase.Text      = 'База 1С:'
$lblBase.Location  = New-Object System.Drawing.Point(12, 74)
$lblBase.AutoSize  = $true

$cmbBase                = New-Object System.Windows.Forms.ComboBox
$cmbBase.Location       = New-Object System.Drawing.Point(12, 94)
$cmbBase.Size           = New-Object System.Drawing.Size(518, 26)
$cmbBase.DropDownStyle  = 'DropDownList'
$cmbBase.FlatStyle      = 'System'
$cmbBase.DrawMode       = 'OwnerDrawFixed'
$cmbBase.ItemHeight     = 18
$cmbBase.add_DrawItem({
    $e = $_
    $palette = Get-UiPalette -Name $script:uiTheme
    $isEdit = ($e.State -band [System.Windows.Forms.DrawItemState]::ComboBoxEdit) -eq [System.Windows.Forms.DrawItemState]::ComboBoxEdit
    $isSelected = (-not $isEdit) -and (($e.State -band [System.Windows.Forms.DrawItemState]::Selected) -eq [System.Windows.Forms.DrawItemState]::Selected)
    $back = if ($isSelected) { $palette.Accent } else { $palette.InputBack }
    $fore = if ($isSelected) { $palette.AccentFore } else { $palette.Fore }
    $backBrush = New-Object System.Drawing.SolidBrush $back
    try {
        $e.Graphics.FillRectangle($backBrush, $e.Bounds)
        if ($e.Index -ge 0 -and $e.Index -lt $cmbBase.Items.Count) {
            $textRect = New-Object System.Drawing.Rectangle(($e.Bounds.X + 2), $e.Bounds.Y, [Math]::Max(0, $e.Bounds.Width - 4), $e.Bounds.Height)
            $flags = [System.Windows.Forms.TextFormatFlags]::Left -bor `
                     [System.Windows.Forms.TextFormatFlags]::VerticalCenter -bor `
                     [System.Windows.Forms.TextFormatFlags]::EndEllipsis -bor `
                     [System.Windows.Forms.TextFormatFlags]::NoPrefix
            [System.Windows.Forms.TextRenderer]::DrawText($e.Graphics, [string]$cmbBase.Items[$e.Index], $e.Font, $textRect, $fore, $flags)
        }
    } finally {
        $backBrush.Dispose()
    }
})

$btnRefreshBases          = New-Object System.Windows.Forms.Button
$btnRefreshBases.Text     = 'Обновить'
$btnRefreshBases.Location = New-Object System.Drawing.Point(538, 92)
$btnRefreshBases.Size     = New-Object System.Drawing.Size(110, 28)
$btnRefreshBases.FlatStyle = 'System'

# ── Кнопка «Прочитать» + счётчик ─────────────────────────────────────────────
$btnRead            = New-Object System.Windows.Forms.Button
$btnRead.Text       = 'Прочитать изменения'
$btnRead.Location   = New-Object System.Drawing.Point(12, 136)
$btnRead.Size       = New-Object System.Drawing.Size(194, 28)
$btnRead.FlatStyle  = 'System'

$lblFound           = New-Object System.Windows.Forms.Label
$lblFound.Text      = 'Изменений не найдено'
$lblFound.Location  = New-Object System.Drawing.Point(214, 141)
$lblFound.Size      = New-Object System.Drawing.Size(434, 20)
$lblFound.Name      = 'lblFound'

# ── Список файлов с чекбоксами ────────────────────────────────────────────────
$lblFiles           = New-Object System.Windows.Forms.Label
$lblFiles.Text      = 'Файлы для загрузки:'
$lblFiles.Location  = New-Object System.Drawing.Point(12, 178)
$lblFiles.AutoSize  = $true

$toolTip = New-Object System.Windows.Forms.ToolTip

$chkSelectAll          = New-Object System.Windows.Forms.CheckBox
$chkSelectAll.Text     = ''
$chkSelectAll.Location = New-Object System.Drawing.Point(600, 176)
$chkSelectAll.Size     = New-Object System.Drawing.Size(20, 20)
$chkSelectAll.Checked  = $true
$toolTip.SetToolTip($chkSelectAll, 'Выделить все')

$chkDeselectAll          = New-Object System.Windows.Forms.CheckBox
$chkDeselectAll.Text     = ''
$chkDeselectAll.Location = New-Object System.Drawing.Point(628, 176)
$chkDeselectAll.Size     = New-Object System.Drawing.Size(20, 20)
$chkDeselectAll.Checked  = $false
$toolTip.SetToolTip($chkDeselectAll, 'Снять выделение')

$checkedList                    = New-Object System.Windows.Forms.CheckedListBox
$checkedList.Location           = New-Object System.Drawing.Point(12, 198)
$checkedList.Size               = New-Object System.Drawing.Size(636, 220)
$checkedList.CheckOnClick       = $true
$checkedList.HorizontalScrollbar = $true
$checkedList.IntegralHeight     = $false
$checkedList.BorderStyle        = 'FixedSingle'

# ── Окно настроек ─────────────────────────────────────────────────────────────
$settingsForm                  = New-Object System.Windows.Forms.Form
$settingsForm.Text             = 'Настройки'
$settingsForm.ClientSize       = New-Object System.Drawing.Size(460, 140)
$settingsForm.FormBorderStyle  = 'FixedDialog'
$settingsForm.MaximizeBox      = $false
$settingsForm.MinimizeBox      = $false
$settingsForm.ShowInTaskbar    = $false
$settingsForm.StartPosition    = 'CenterParent'
$settingsForm.Font             = $form.Font
$settingsForm.add_HandleCreated({
    try { [NativeTheme]::Apply($settingsForm.Handle, ($script:uiTheme -eq 'Dark')) } catch {}
})

$chkOpenConf          = New-Object System.Windows.Forms.CheckBox
$chkOpenConf.Text     = 'Открыть конфигуратор после успешной загрузки'
$chkOpenConf.Location = New-Object System.Drawing.Point(16, 16)
$chkOpenConf.Size     = New-Object System.Drawing.Size(428, 22)
$chkOpenConf.Checked  = $false

$chkSkipDbUpdate          = New-Object System.Windows.Forms.CheckBox
$chkSkipDbUpdate.Text     = 'Не обновлять конфигурацию базы данных'
$chkSkipDbUpdate.Location = New-Object System.Drawing.Point(16, 46)
$chkSkipDbUpdate.Size     = New-Object System.Drawing.Size(428, 22)
$chkSkipDbUpdate.Checked  = $false

$btnTheme           = New-Object System.Windows.Forms.Button
$btnTheme.Text      = 'Тёмная тема'
$btnTheme.Location  = New-Object System.Drawing.Point(16, 88)
$btnTheme.Size      = New-Object System.Drawing.Size(160, 32)
$btnTheme.FlatStyle = 'System'

$savedOptions = Read-SavedUiOptions
$chkOpenConf.Checked = [bool]$savedOptions.OpenConf
$chkSkipDbUpdate.Checked = [bool]$savedOptions.SkipDbUpdate

$settingsForm.Controls.AddRange(@($chkOpenConf, $chkSkipDbUpdate, $btnTheme))

# ── Разделитель ───────────────────────────────────────────────────────────────
$sep            = New-Object System.Windows.Forms.Panel
$sep.Location   = New-Object System.Drawing.Point(0, 430)
$sep.Size       = New-Object System.Drawing.Size(660, 1)
$sep.BackColor  = [System.Drawing.Color]::FromArgb(220, 220, 220)

# ── Статус + кнопка «Загрузить» ───────────────────────────────────────────────
$lblStatus           = New-Object System.Windows.Forms.Label
$lblStatus.Text      = 'Выберите папку и базу, затем нажмите "Прочитать изменения"'
$lblStatus.Location  = New-Object System.Drawing.Point(12, 438)
$lblStatus.Size      = New-Object System.Drawing.Size(400, 36)
$lblStatus.Name      = 'lblStatus'

$btnLoad             = New-Object System.Windows.Forms.Button
$btnLoad.Text        = 'Загрузить выбранные'
$btnLoad.Location    = New-Object System.Drawing.Point(444, 436)
$btnLoad.Size        = New-Object System.Drawing.Size(204, 36)
$btnLoad.Enabled     = $false
$btnLoad.FlatStyle   = 'Flat'
$btnLoad.Font        = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
$btnLoad.BackColor   = [System.Drawing.Color]::FromArgb(0, 120, 215)
$btnLoad.ForeColor   = [System.Drawing.Color]::White
$btnLoad.FlatAppearance.BorderSize = 0

$form.Controls.AddRange(@(
    $lblPath, $lblSettings, $txtPath, $btnBrowse,
    $lblBase, $cmbBase, $btnRefreshBases,
    $btnRead, $lblFound,
    $lblFiles, $chkSelectAll, $chkDeselectAll, $checkedList,
    $sep, $lblStatus, $btnLoad
))

$settingsRowHeight = 22
foreach ($ctrl in @($form.Controls)) {
    if ($ctrl -ne $lblSettings) { $ctrl.Top += $settingsRowHeight }
}
$form.ClientSize = New-Object System.Drawing.Size($form.ClientSize.Width, ($form.ClientSize.Height + $settingsRowHeight))

# ─────────────────────────────────────────────────────────────────────────────
# Таймер — опрос процесса загрузки (не блокирует UI)
# ─────────────────────────────────────────────────────────────────────────────
$loadTimer          = New-Object System.Windows.Forms.Timer
$loadTimer.Interval = 1000

$loadTimer.add_Tick({
    $script:loadTicks++
    $dots = '.' * (($script:loadTicks % 3) + 1)

    $done = ($null -eq $script:loadProc) -or $script:loadProc.HasExited

    if ($done) {
        $loadTimer.Stop()
        $exitCode = if ($null -ne $script:loadProc) { $script:loadProc.ExitCode } else { -1 }

        $script:loadProc = $null

        # Восстановить .1c-devbase.bat
        if ($null -ne $script:devbaseState) {
            Restore-DevBase -State $script:devbaseState
            $script:devbaseState = $null
        }

        # Разблокировать UI
        $btnRead.Enabled = $true
        $cmbBase.Enabled = $true
        $btnRefreshBases.Enabled = $true
        $btnLoad.Enabled = ($checkedList.CheckedItems.Count -gt 0)

        if ($exitCode -eq 0) {
            Set-LabelTone -Label $lblStatus -Tone Success
            $lblStatus.Text      = 'Загрузка завершена успешно!'
            [System.Windows.Forms.MessageBox]::Show(
                'Загрузка завершена успешно!',
                '1С Загрузчик',
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Information
            ) | Out-Null

            # Открыть конфигуратор если опция выбрана
            if ($chkOpenConf.Checked -and $null -ne $script:loadingBase -and $script:loadingOnecExe) {
                Open-1CConfigurator -OnecExePath $script:loadingOnecExe -Database $script:loadingBase
            }
            $script:loadingBase = $null
        } else {
            Set-LabelTone -Label $lblStatus -Tone Error
            $lblStatus.Text      = "Ошибка загрузки (код: $exitCode)."
            [System.Windows.Forms.MessageBox]::Show(
                "Загрузка завершилась с ошибкой.`nКод возврата: $exitCode`n`nДиагностика: $env:TEMP\1c-loader-last-cmd.txt",
                '1С Загрузчик',
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Error
            ) | Out-Null
        }
    } else {
        $elapsed = $script:loadTicks
        $lblStatus.Text = "Загрузка$dots  (${elapsed}с)"
    }
})

$btnBrowse.add_EnabledChanged({ Update-SecondaryButtonsForEnabledState })
$btnRefreshBases.add_EnabledChanged({ Update-SecondaryButtonsForEnabledState })
$btnRead.add_EnabledChanged({ Update-SecondaryButtonsForEnabledState })
$btnLoad.add_EnabledChanged({ Update-SecondaryButtonsForEnabledState })

# ─────────────────────────────────────────────────────────────────────────────
# Обработчики событий
# ─────────────────────────────────────────────────────────────────────────────

# ── Настройки ────────────────────────────────────────────────────────────────
$lblSettings.add_Click({
    $settingsForm.ShowDialog($form) | Out-Null
})

$chkOpenConf.add_CheckedChanged({ Save-UiOptions })
$chkSkipDbUpdate.add_CheckedChanged({ Save-UiOptions })

$btnTheme.add_Click({
    $next = if ($script:uiTheme -eq 'Dark') { 'Light' } else { 'Dark' }
    Set-UiTheme -Name $next
    Save-UiTheme -Name $next
})

# ── «Обзор» ──────────────────────────────────────────────────────────────────
$btnBrowse.add_Click({
    $initial  = if ($txtPath.Text -and (Test-Path $txtPath.Text -PathType Container)) { $txtPath.Text } else { $null }

    # Современный диалог проводника (IFileOpenDialog)
    try {
        $selected = [ModernFolderPicker]::Show($form.Handle, $initial)
    } catch {
        # Фолбэк на старый FolderBrowserDialog
        $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
        $dlg.Description = 'Выберите папку проекта'
        $dlg.ShowNewFolderButton = $false
        if ($initial) { $dlg.SelectedPath = $initial }
        $selected = if ($dlg.ShowDialog($form) -eq [System.Windows.Forms.DialogResult]::OK) { $dlg.SelectedPath } else { $null }
    }

    if ($selected) {
        $txtPath.Text = $selected
        # Сбросить результаты предыдущего чтения
        $checkedList.Items.Clear()
        $lblFound.Text      = 'Изменений не найдено'
        Set-LabelTone -Label $lblFound -Tone Muted
        $btnLoad.Enabled    = $false
        Set-LabelTone -Label $lblStatus -Tone Muted
        $lblStatus.Text     = 'Папка выбрана. Нажмите "Прочитать изменения".'
    }
})

# ── «Обновить» список баз ────────────────────────────────────────────────────
$btnRefreshBases.add_Click({
    Update-BasesComboBox
})

# ── «Прочитать изменения» ────────────────────────────────────────────────────
$btnRead.add_Click({
    $folderPath = $txtPath.Text.Trim()

    # Сброс
    $checkedList.Items.Clear()
    $btnLoad.Enabled    = $false
    Set-LabelTone -Label $lblFound -Tone Muted
    Set-LabelTone -Label $lblStatus -Tone Muted

    # Валидация
    if (-not $folderPath) {
        $lblStatus.Text = 'Сначала выберите папку проекта.'
        return
    }
    if (-not (Test-Path $folderPath -PathType Container)) {
        $lblStatus.Text = "Папка не найдена: $folderPath"
        return
    }
    if (-not (Test-GitInstalled)) {
        $lblStatus.Text = 'Ошибка: git не найден в PATH. Установите Git for Windows.'
        return
    }

    $script:gitRoot = Find-GitRoot -StartPath $folderPath
    if (-not $script:gitRoot) {
        $lblStatus.Text = 'Ошибка: папка не является git-репозиторием (нет .git).'
        return
    }

    $script:xmlDir = Find-OnecXmlRoot -StartPath $folderPath
    if (-not $script:xmlDir) { $script:xmlDir = $folderPath }

    $script:subPathFilter = ''
    if ($script:xmlDir -ne $script:gitRoot) {
        $script:subPathFilter = $script:xmlDir.Substring($script:gitRoot.Length).TrimStart('\', '/').Replace('\', '/')
    }

    $lblStatus.Text = 'Читаем git diff...'
    [System.Windows.Forms.Application]::DoEvents()

    try {
        [string[]]$files = @(Get-GitChangedFiles -GitRoot $script:gitRoot -SubPath $script:subPathFilter)
    } catch {
        $lblStatus.Text = "Ошибка git: $_"
        return
    }

    if ($files.Count -eq 0) {
        $lblFound.Text  = 'Нет изменений'
        $lblStatus.Text = 'Незакоммиченных изменений в XML/BSL-файлах не обнаружено.'
        return
    }

    foreach ($f in $files) {
        $checkedList.Items.Add($f, $true) | Out-Null
    }

    $lblFound.Text      = "Найдено: $($files.Count) файлов"
    Set-LabelTone -Label $lblFound -Tone Success
    $btnLoad.Text       = "Загрузить выбранные ($($files.Count))"
    $btnLoad.Enabled    = $true
    Set-LabelTone -Label $lblStatus -Tone Muted
    $lblStatus.Text     = 'Снимите галочки с ненужных файлов и нажмите "Загрузить".'
})

# ── Выделить все / снять выделение ───────────────────────────────────────────
# Визуально: «выделить» всегда с галочкой, «снять» — пустой; клик только действие
$chkSelectAll.add_Click({
    for ($i = 0; $i -lt $checkedList.Items.Count; $i++) {
        $checkedList.SetItemChecked($i, $true)
    }
    $chkSelectAll.Checked   = $true
    $chkDeselectAll.Checked = $false
})

$chkDeselectAll.add_Click({
    for ($i = 0; $i -lt $checkedList.Items.Count; $i++) {
        $checkedList.SetItemChecked($i, $false)
    }
    $chkSelectAll.Checked   = $true
    $chkDeselectAll.Checked = $false
})

# ── Изменение чекбокса — обновить счётчик на кнопке ─────────────────────────
$checkedList.add_ItemCheck({
    $e = $_
    # ItemCheck срабатывает ДО смены состояния — корректируем счётчик вручную
    $newCount = $checkedList.CheckedItems.Count
    if ($e.NewValue -eq [System.Windows.Forms.CheckState]::Checked)   { $newCount++ }
    elseif ($e.NewValue -eq [System.Windows.Forms.CheckState]::Unchecked) { $newCount-- }

    if ($newCount -gt 0) {
        $btnLoad.Text    = "Загрузить выбранные ($newCount)"
        $btnLoad.Enabled = $true
    } else {
        $btnLoad.Text    = 'Загрузить выбранные'
        $btnLoad.Enabled = $false
    }
})

# ── «Загрузить» ───────────────────────────────────────────────────────────────
$btnLoad.add_Click({
    if ($cmbBase.SelectedIndex -lt 0 -or $script:bases.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show('Выберите базу 1С.', '1С Загрузчик', 'OK', 'Warning') | Out-Null
        return
    }

    $selectedBase = $script:bases[$cmbBase.SelectedIndex]
    $script:loadingBase = $selectedBase

    # Собрать отмеченные файлы
    $checkedFiles = @($checkedList.CheckedItems | ForEach-Object { "$_" })
    if ($checkedFiles.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show('Нет выбранных файлов.', '1С Загрузчик', 'OK', 'Warning') | Out-Null
        return
    }

    # Привести к путям относительно xmlDir
    $relFiles = @($checkedFiles | ForEach-Object {
        if ($script:subPathFilter) { $_.Substring($script:subPathFilter.Length).TrimStart('/') }
        else                       { $_ }
    })

    # Найти 1cv8.exe по версии из ibases.v8i
    $requiredVer = Get-BasePlatformVersion -Base $selectedBase
    $platform    = Find-1CExecutable -RequiredVersion $requiredVer
    if (-not $platform.Path) {
        [System.Windows.Forms.MessageBox]::Show(
            '1cv8.exe не найден. Установите платформу 1С:Предприятие.',
            '1С Загрузчик', 'OK', 'Error'
        ) | Out-Null
        return
    }
    $onecExe = $platform.Path
    $script:loadingOnecExe = $onecExe

    # Проверить: не открыт ли конфигуратор для этой базы
    $baseRef  = if ($selectedBase.IsServer) { $selectedBase.Ref } else { $selectedBase.FilePath }
    $confProc = Get-WmiObject Win32_Process -Filter "Name='1cv8.exe'" -ErrorAction SilentlyContinue |
                    Where-Object { $_.CommandLine -match 'DESIGNER' -and $_.CommandLine -match [regex]::Escape($baseRef) }
    if ($confProc) {
        [System.Windows.Forms.MessageBox]::Show(
            "Конфигуратор базы `"$($selectedBase.Name)`" уже открыт.`n`nЗакройте конфигуратор и повторите загрузку.",
            '1С Загрузчик', 'OK', 'Warning'
        ) | Out-Null
        return
    }

    # Заблокировать UI
    $btnLoad.Enabled  = $false
    $btnRead.Enabled  = $false
    $cmbBase.Enabled  = $false
    $btnRefreshBases.Enabled = $false
    Set-LabelTone -Label $lblStatus -Tone Progress
    if ($platform.Warning) {
        $lblStatus.Text = "Платформа: $($platform.MatchedVersion). $($platform.Warning)"
    } elseif ($requiredVer) {
        $lblStatus.Text = "Платформа: $requiredVer → $($platform.MatchedVersion). Подготовка..."
    } else {
        $lblStatus.Text = "Платформа: $($platform.MatchedVersion). Подготовка..."
    }

    # Создать временный .1c-devbase.bat
    try {
        $script:devbaseState = Write-TempDevBase `
            -ProjectRoot $script:gitRoot `
            -Database    $selectedBase `
            -OnecExePath $onecExe
    } catch {
        Set-LabelTone -Label $lblStatus -Tone Error
        $lblStatus.Text   = "Ошибка создания .1c-devbase.bat: $_"
        $btnLoad.Enabled  = $true
        $btnRead.Enabled  = $true
        $cmbBase.Enabled  = $true
        $btnRefreshBases.Enabled = $true
        return
    }

    # Запустить загрузку асинхронно (без -Wait — UI не зависает)
    try {
        $script:loadTicks = 0
        $script:loadProc  = Start-1CLoad `
            -WorkingDirectory $script:gitRoot `
            -XmlDir           $script:xmlDir `
            -RelFiles         $relFiles `
            -SkipDbUpdate:($chkSkipDbUpdate.Checked)

        $lblStatus.Text = 'Загрузка запущена...'
        $loadTimer.Start()
    } catch {
        if ($null -ne $script:devbaseState) {
            Restore-DevBase -State $script:devbaseState
            $script:devbaseState = $null
        }
        Set-LabelTone -Label $lblStatus -Tone Error
        $lblStatus.Text   = "Ошибка запуска загрузки: $_"
        $btnLoad.Enabled  = $true
        $btnRead.Enabled  = $true
        $cmbBase.Enabled  = $true
        $btnRefreshBases.Enabled = $true
    }
})

# ─────────────────────────────────────────────────────────────────────────────
# Инициализация
# ─────────────────────────────────────────────────────────────────────────────

Update-BasesComboBox

# Очистка при закрытии формы
$form.add_FormClosing({
    $loadTimer.Stop()
    if ($null -ne $script:devbaseState) {
        Restore-DevBase -State $script:devbaseState
    }
})

# ─────────────────────────────────────────────────────────────────────────────
# Запуск
# ─────────────────────────────────────────────────────────────────────────────
Set-UiTheme -Name (Read-SavedUiTheme)
[System.Windows.Forms.Application]::Run($form)
