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

        [string[]]$all = @(
            (@($unstaged) + $staged) |
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

function Find-1CExecutable {
    foreach ($rp in @('HKLM:\SOFTWARE\1C\1Cv8', 'HKLM:\SOFTWARE\WOW6432Node\1C\1Cv8')) {
        if (-not (Test-Path $rp)) { continue }
        foreach ($v in (Get-ChildItem $rp -ErrorAction SilentlyContinue | Sort-Object Name -Descending)) {
            try {
                $loc = (Get-ItemProperty $v.PSPath -ErrorAction Stop).InstallLocation
                if ($loc) { $e = Join-Path $loc 'bin\1cv8.exe'; if (Test-Path $e) { return $e } }
            } catch { continue }
        }
    }
    foreach ($root in @('C:\Program Files\1cv8', 'C:\Program Files (x86)\1cv8')) {
        if (-not (Test-Path $root)) { continue }
        foreach ($v in (Get-ChildItem $root -Directory -ErrorAction SilentlyContinue | Sort-Object Name -Descending)) {
            $e = Join-Path $v.FullName 'bin\1cv8.exe'
            if (Test-Path $e) { return $e }
        }
    }
    return $null
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
            $cur = [pscustomobject]@{ Name = $Matches[1].Trim(); Server = ''; Ref = ''; FilePath = ''; IsServer = $false }
        } elseif ($cur -and $line -match '^Connect\s*=\s*(.+)$') {
            $conn = $Matches[1].TrimEnd(';')
            if ($conn -match 'Srvr\s*=\s*"([^"]*)"') { $cur.Server = $Matches[1]; $cur.IsServer = $true }
            if ($conn -match 'Ref\s*=\s*"([^"]*)"')  { $cur.Ref    = $Matches[1] }
            if ($conn -match 'File\s*=\s*"([^"]*)"') { $cur.FilePath = $Matches[1] }
        }
    }
    if ($cur) { $list.Add($cur) }
    return @($list | Where-Object { $_.Server -or $_.FilePath })
}

function Start-1CLoad {
    # Запускает 1cv8.exe DESIGNER /LoadConfigFromFiles напрямую, без посредников
    param(
        [string]$OnecExePath,
        [pscustomobject]$Database,
        [string]$XmlDir,
        [string[]]$RelFiles,
        [switch]$SkipDbUpdate
    )
    if ($Database.IsServer) {
        $connArg = "/S `"$($Database.Server)\$($Database.Ref)`""
    } else {
        $connArg = "/F `"$($Database.FilePath)`""
    }

    $fileList  = ($RelFiles | ForEach-Object { $_.Replace('/', '\') }) -join ','
    $designerArgs = "DESIGNER $connArg /LoadConfigFromFiles `"$XmlDir`""
    if ($fileList)          { $designerArgs += " /files `"$fileList`"" }
    if (-not $SkipDbUpdate) { $designerArgs += ' /UpdateDBCfg' }

    return Start-Process $OnecExePath -ArgumentList $designerArgs -WindowStyle Hidden -PassThru
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
$script:loadProc      = $null
$script:loadTicks     = 0
$script:loadingBase   = $null

# ─────────────────────────────────────────────────────────────────────────────
# Форма
# ─────────────────────────────────────────────────────────────────────────────
$form                  = New-Object System.Windows.Forms.Form
$form.Text             = '1С: Загрузка изменённых файлов'
$form.ClientSize       = New-Object System.Drawing.Size(660, 480)
$form.FormBorderStyle  = 'FixedSingle'
$form.MaximizeBox      = $false
$form.StartPosition    = 'CenterScreen'
$form.Font             = New-Object System.Drawing.Font('Segoe UI', 9)
$form.BackColor        = [System.Drawing.Color]::White

# ── Папка проекта ─────────────────────────────────────────────────────────────
$lblPath           = New-Object System.Windows.Forms.Label
$lblPath.Text      = 'Папка проекта:'
$lblPath.Location  = New-Object System.Drawing.Point(12, 14)
$lblPath.AutoSize  = $true

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
$cmbBase.Size           = New-Object System.Drawing.Size(636, 26)
$cmbBase.DropDownStyle  = 'DropDownList'
$cmbBase.FlatStyle      = 'System'

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
$lblFound.ForeColor = [System.Drawing.Color]::Gray

# ── Список файлов с чекбоксами ────────────────────────────────────────────────
$lblFiles           = New-Object System.Windows.Forms.Label
$lblFiles.Text      = 'Файлы для загрузки:'
$lblFiles.Location  = New-Object System.Drawing.Point(12, 178)
$lblFiles.AutoSize  = $true

$checkedList                    = New-Object System.Windows.Forms.CheckedListBox
$checkedList.Location           = New-Object System.Drawing.Point(12, 198)
$checkedList.Size               = New-Object System.Drawing.Size(636, 172)
$checkedList.CheckOnClick       = $true
$checkedList.HorizontalScrollbar = $true
$checkedList.IntegralHeight     = $false
$checkedList.BorderStyle        = 'FixedSingle'

# ── Чекбокс «Открыть конфигуратор» ───────────────────────────────────────────
$chkOpenConf          = New-Object System.Windows.Forms.CheckBox
$chkOpenConf.Text     = 'Открыть конфигуратор после успешной загрузки'
$chkOpenConf.Location = New-Object System.Drawing.Point(12, 380)
$chkOpenConf.Size     = New-Object System.Drawing.Size(420, 20)
$chkOpenConf.Checked  = $false

# ── Разделитель ───────────────────────────────────────────────────────────────
$sep            = New-Object System.Windows.Forms.Panel
$sep.Location   = New-Object System.Drawing.Point(0, 410)
$sep.Size       = New-Object System.Drawing.Size(660, 1)
$sep.BackColor  = [System.Drawing.Color]::FromArgb(220, 220, 220)

# ── Статус + кнопка «Загрузить» ───────────────────────────────────────────────
$lblStatus           = New-Object System.Windows.Forms.Label
$lblStatus.Text      = 'Выберите папку и базу, затем нажмите "Прочитать изменения"'
$lblStatus.Location  = New-Object System.Drawing.Point(12, 418)
$lblStatus.Size      = New-Object System.Drawing.Size(400, 36)
$lblStatus.ForeColor = [System.Drawing.Color]::Gray

$btnLoad             = New-Object System.Windows.Forms.Button
$btnLoad.Text        = 'Загрузить выбранные'
$btnLoad.Location    = New-Object System.Drawing.Point(444, 416)
$btnLoad.Size        = New-Object System.Drawing.Size(204, 36)
$btnLoad.Enabled     = $false
$btnLoad.FlatStyle   = 'Flat'
$btnLoad.Font        = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
$btnLoad.BackColor   = [System.Drawing.Color]::FromArgb(0, 120, 215)
$btnLoad.ForeColor   = [System.Drawing.Color]::White
$btnLoad.FlatAppearance.BorderSize = 0

$form.Controls.AddRange(@(
    $lblPath, $txtPath, $btnBrowse,
    $lblBase, $cmbBase,
    $btnRead, $lblFound,
    $lblFiles, $checkedList,
    $chkOpenConf,
    $sep, $lblStatus, $btnLoad
))

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

        # Разблокировать UI
        $btnRead.Enabled = $true
        $cmbBase.Enabled = $true
        $btnLoad.Enabled = ($checkedList.CheckedItems.Count -gt 0)

        if ($exitCode -eq 0) {
            $lblStatus.ForeColor = [System.Drawing.Color]::FromArgb(0, 128, 0)
            $lblStatus.Text      = 'Загрузка завершена успешно!'
            [System.Windows.Forms.MessageBox]::Show(
                'Загрузка завершена успешно!',
                '1С Загрузчик',
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Information
            ) | Out-Null

            # Открыть конфигуратор если опция выбрана
            if ($chkOpenConf.Checked -and $null -ne $script:loadingBase) {
                $onecExe = Find-1CExecutable
                if ($onecExe) {
                    Open-1CConfigurator -OnecExePath $onecExe -Database $script:loadingBase
                }
            }
            $script:loadingBase = $null
        } else {
            $lblStatus.ForeColor = [System.Drawing.Color]::Red
            $lblStatus.Text      = "Ошибка загрузки (код: $exitCode)."
            [System.Windows.Forms.MessageBox]::Show(
                "Загрузка завершилась с ошибкой.`nКод возврата: $exitCode",
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

# ─────────────────────────────────────────────────────────────────────────────
# Обработчики событий
# ─────────────────────────────────────────────────────────────────────────────

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
        $lblFound.ForeColor = [System.Drawing.Color]::Gray
        $btnLoad.Enabled    = $false
        $lblStatus.ForeColor = [System.Drawing.Color]::Gray
        $lblStatus.Text     = 'Папка выбрана. Нажмите "Прочитать изменения".'
    }
})

# ── «Прочитать изменения» ────────────────────────────────────────────────────
$btnRead.add_Click({
    $folderPath = $txtPath.Text.Trim()

    # Сброс
    $checkedList.Items.Clear()
    $btnLoad.Enabled    = $false
    $lblFound.ForeColor = [System.Drawing.Color]::Gray
    $lblStatus.ForeColor = [System.Drawing.Color]::Gray

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
    $lblFound.ForeColor = [System.Drawing.Color]::FromArgb(0, 128, 0)
    $btnLoad.Text       = "Загрузить выбранные ($($files.Count))"
    $btnLoad.Enabled    = $true
    $lblStatus.ForeColor = [System.Drawing.Color]::Gray
    $lblStatus.Text     = 'Снимите галочки с ненужных файлов и нажмите "Загрузить".'
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

    # Найти 1cv8.exe
    $onecExe = Find-1CExecutable
    if (-not $onecExe) {
        [System.Windows.Forms.MessageBox]::Show(
            '1cv8.exe не найден. Установите платформу 1С:Предприятие.',
            '1С Загрузчик', 'OK', 'Error'
        ) | Out-Null
        return
    }

    # Заблокировать UI
    $btnLoad.Enabled  = $false
    $btnRead.Enabled  = $false
    $cmbBase.Enabled  = $false
    $lblStatus.ForeColor = [System.Drawing.Color]::FromArgb(0, 102, 204)
    $lblStatus.Text   = 'Запуск загрузки...'

    # Запустить загрузку асинхронно (без -Wait — UI не зависает)
    try {
        $script:loadTicks = 0
        $script:loadProc  = Start-1CLoad `
            -OnecExePath $onecExe `
            -Database    $selectedBase `
            -XmlDir      $script:xmlDir `
            -RelFiles    $relFiles

        $lblStatus.Text = 'Загрузка запущена...'
        $loadTimer.Start()
    } catch {
        $lblStatus.ForeColor = [System.Drawing.Color]::Red
        $lblStatus.Text   = "Ошибка запуска загрузки: $_"
        $btnLoad.Enabled  = $true
        $btnRead.Enabled  = $true
        $cmbBase.Enabled  = $true
    }
})

# ─────────────────────────────────────────────────────────────────────────────
# Инициализация
# ─────────────────────────────────────────────────────────────────────────────

# Заполнить ComboBox из ibases.v8i
$allBases = Get-IBasesList
if ($allBases -and $allBases.Count -gt 0) {
    $script:bases = $allBases
    foreach ($b in $allBases) {
        $label = if ($b.IsServer) {
            "$($b.Name)   [$($b.Server) / $($b.Ref)]"
        } else {
            "$($b.Name)   [$($b.FilePath)]"
        }
        $cmbBase.Items.Add($label) | Out-Null
    }
    $cmbBase.SelectedIndex = 0
} else {
    $cmbBase.Items.Add('Базы не найдены — запустите 1С:Предприятие и добавьте базы') | Out-Null
    $cmbBase.Enabled = $false
}

# Очистка при закрытии формы
$form.add_FormClosing({
    $loadTimer.Stop()
})

# ─────────────────────────────────────────────────────────────────────────────
# Запуск
# ─────────────────────────────────────────────────────────────────────────────
[System.Windows.Forms.Application]::Run($form)
