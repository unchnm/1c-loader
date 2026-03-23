#Requires -Version 5.1
<#
.SYNOPSIS
    Загружает изменённые (по git) XML/BSL-файлы в выбранную базу 1С.

.DESCRIPTION
    Определяет незакоммиченные изменения, фильтрует XML/BSL,
    предлагает выбрать базу из стандартного списка клиента 1С
    и загружает только изменённые файлы через частичную загрузку конфигурации.

.PARAMETER Path
    Путь к папке проекта (папка с XML/BSL или корень git-репо).
    Если не задан — открывается диалог выбора папки.

.PARAMETER WindowsAuth
    Использовать доменную аутентификацию Windows (по умолчанию).

.PARAMETER User
    Имя пользователя 1С. Если задан — используется вместо WindowsAuth.

.PARAMETER Password
    Пароль пользователя 1С (используется вместе с -User).

.PARAMETER SkipDbUpdate
    Пропустить обновление конфигурации БД после загрузки.

.PARAMETER DryRun
    Показать список изменённых файлов без загрузки в базу.

.EXAMPLE
    .\Deploy-1C-Changes.ps1
    Интерактивный режим, доменная аутентификация.

.EXAMPLE
    .\Deploy-1C-Changes.ps1 -Path "D:\Projects\MyProject\src\cf" -DryRun

.EXAMPLE
    .\Deploy-1C-Changes.ps1 -User "Admin" -Password "secret"
#>
[CmdletBinding()]
param(
    [string]$Path         = '',
    [switch]$WindowsAuth,
    [string]$User         = '',
    [string]$Password     = '',
    [switch]$SkipDbUpdate,
    [switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# ─────────────────────────────────────────────────────────────────────────────
# Вывод
# ─────────────────────────────────────────────────────────────────────────────

function Write-Banner {
    Write-Host ''
    Write-Host '  +-----------------------------------------+' -ForegroundColor Cyan
    Write-Host '  |  1C: Загрузка изменённых файлов          |' -ForegroundColor Cyan
    Write-Host '  +-----------------------------------------+' -ForegroundColor Cyan
    Write-Host ''
}

function Write-Step {
    param([string]$Number, [string]$Title)
    Write-Host ''
    Write-Host "  [$Number] $Title" -ForegroundColor Cyan
    Write-Host "  $('─' * ($Title.Length + 4))" -ForegroundColor DarkCyan
}

function Write-Ok   { param([string]$Text); Write-Host "    OK  $Text" -ForegroundColor Green }
function Write-Info { param([string]$Text); Write-Host "    ..  $Text" -ForegroundColor DarkGray }
function Write-Warn { param([string]$Text); Write-Host "    !!  $Text" -ForegroundColor Yellow }
function Write-Fail { param([string]$Text); Write-Host "    XX  $Text" -ForegroundColor Red }

function Exit-Script {
    param([int]$Code = 0)
    Write-Host ''
    Read-Host '  Нажмите Enter для выхода'
    exit $Code
}

# ─────────────────────────────────────────────────────────────────────────────
# Шаг 1: Выбор папки
# ─────────────────────────────────────────────────────────────────────────────

function Select-ProjectFolder {
    param([string]$InitialPath = '')

    if ($InitialPath -and (Test-Path $InitialPath -PathType Container)) {
        return (Resolve-Path $InitialPath).ProviderPath
    }

    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
        $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
        $dialog.Description = 'Выберите папку проекта (папку с XML/BSL-файлами или корень git-репозитория)'
        $dialog.ShowNewFolderButton = $false
        $result = $dialog.ShowDialog()
        if ($result -eq [System.Windows.Forms.DialogResult]::OK -and $dialog.SelectedPath) {
            return $dialog.SelectedPath
        }
        Write-Warn 'Диалог отменён.'
    } catch {
        Write-Info 'Диалог недоступен, используется ввод в консоли.'
    }

    Write-Host ''
    $manual = Read-Host '  Введите путь к папке проекта'
    $manual = $manual.Trim('"').Trim("'").Trim()
    if ($manual -and (Test-Path $manual -PathType Container)) {
        return (Resolve-Path $manual).ProviderPath
    }

    return $null
}

# ─────────────────────────────────────────────────────────────────────────────
# Шаг 2: Git
# ─────────────────────────────────────────────────────────────────────────────

function Test-GitInstalled {
    try {
        $null = & git --version 2>&1
        return ($LASTEXITCODE -eq 0)
    } catch {
        return $false
    }
}

function Find-GitRoot {
    param([string]$StartPath)
    $current = $StartPath
    while ($current) {
        if (Test-Path (Join-Path $current '.git')) { return $current }
        $parent = Split-Path $current -Parent
        if ($parent -eq $current) { break }
        $current = $parent
    }
    return $null
}

function Get-GitChangedFiles {
    param([string]$GitRoot, [string]$SubPath = '')
    Push-Location $GitRoot
    try {
        # Незакоммиченные изменения рабочей копии (изменённые, добавленные в индекс)
        $unstaged = & git diff HEAD --name-only --diff-filter=ACMR 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw ('git diff завершился с ошибкой: ' + ($unstaged -join ' '))
        }

        # Проиндексированные изменения (staged vs HEAD)
        $staged = @(& git diff --cached --name-only --diff-filter=ACMR 2>&1)
        if ($LASTEXITCODE -ne 0) { $staged = @() }

        # Новые (неотслеживаемые) файлы
        $untracked = @(& git ls-files --others --exclude-standard 2>&1)
        if ($LASTEXITCODE -ne 0) { $untracked = @() }

        [string[]]$allFiles = @(
            (@($unstaged) + $staged + $untracked) |
                Where-Object { $_ -and ($_ -match '\.(xml|bsl)$') } |
                ForEach-Object { $_.Replace('\', '/').Trim() } |
                Where-Object { $_ } |
                Sort-Object -Unique
        )

        if ($SubPath) {
            $prefix = $SubPath.Replace('\', '/').TrimEnd('/') + '/'
            [string[]]$allFiles = @($allFiles | Where-Object { $_ -and $_.StartsWith($prefix) })
        }

        return $allFiles
    } finally {
        Pop-Location
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# Шаг 3: Поиск корня XML конфигурации 1С
# ─────────────────────────────────────────────────────────────────────────────

function Find-OnecXmlRoot {
    <#
        Ищет папку, содержащую Configuration.xml — корень XML-дампа конфигурации 1С.
        Сначала проверяет сам $StartPath, затем типичные подпапки проекта.
        Возвращает найденный путь или $null.
    #>
    param([string]$StartPath)

    # Папка выбрана верно — Configuration.xml прямо в ней
    if (Test-Path (Join-Path $StartPath 'Configuration.xml')) {
        return $StartPath
    }

    # Типичные места хранения XML-дампа в 1С-проектах
    $candidates = @('src', 'src\cf', 'cf', 'config', '1c', 'src\1c', '1c\cf')
    foreach ($sub in $candidates) {
        $candidate = Join-Path $StartPath $sub
        if (Test-Path (Join-Path $candidate 'Configuration.xml')) {
            return $candidate
        }
    }

    # Поиск на один уровень вглубь (произвольные имена папок)
    $subdirs = Get-ChildItem $StartPath -Directory -ErrorAction SilentlyContinue
    foreach ($dir in $subdirs) {
        if (Test-Path (Join-Path $dir.FullName 'Configuration.xml')) {
            return $dir.FullName
        }
    }

    return $null
}

# ─────────────────────────────────────────────────────────────────────────────
# Шаг 4: Поиск 1cv8.exe
# ─────────────────────────────────────────────────────────────────────────────

function Find-1CExecutable {
    $regPaths = @('HKLM:\SOFTWARE\1C\1Cv8', 'HKLM:\SOFTWARE\WOW6432Node\1C\1Cv8')
    foreach ($regPath in $regPaths) {
        if (-not (Test-Path $regPath)) { continue }
        $versions = Get-ChildItem $regPath -ErrorAction SilentlyContinue | Sort-Object Name -Descending
        foreach ($ver in $versions) {
            try {
                $loc = (Get-ItemProperty $ver.PSPath -ErrorAction Stop).InstallLocation
                if ($loc) {
                    $exe = Join-Path $loc 'bin\1cv8.exe'
                    if (Test-Path $exe) { return $exe }
                }
            } catch { continue }
        }
    }

    foreach ($root in @('C:\Program Files\1cv8', 'C:\Program Files (x86)\1cv8')) {
        if (-not (Test-Path $root)) { continue }
        $versions = Get-ChildItem $root -Directory -ErrorAction SilentlyContinue | Sort-Object Name -Descending
        foreach ($ver in $versions) {
            $exe = Join-Path $ver.FullName 'bin\1cv8.exe'
            if (Test-Path $exe) { return $exe }
        }
    }

    return $null
}

# ─────────────────────────────────────────────────────────────────────────────
# Шаг 4: Список баз из ibases.v8i
# ─────────────────────────────────────────────────────────────────────────────

function Get-IBasesList {
    $ibasesPath = Join-Path $env:APPDATA '1C\1CEStart\ibases.v8i'
    if (-not (Test-Path $ibasesPath)) { return $null }

    $content = $null
    foreach ($enc in @([System.Text.Encoding]::UTF8, [System.Text.Encoding]::Unicode, [System.Text.Encoding]::Default)) {
        try {
            $raw = [System.IO.File]::ReadAllText($ibasesPath, $enc)
            if ($raw -match '(?m)^\[') {
                $content = $raw -split '\r?\n'
                break
            }
        } catch { continue }
    }
    if (-not $content) { return $null }

    $bases   = [System.Collections.Generic.List[pscustomobject]]::new()
    $current = $null

    foreach ($line in $content) {
        $line = $line.Trim()
        if (-not $line) { continue }

        if ($line -match '^\[(.+)\]$') {
            if ($null -ne $current) { $bases.Add($current) }
            $current = [pscustomobject]@{
                Name     = $Matches[1].Trim()
                Server   = ''
                Ref      = ''
                FilePath = ''
                IsServer = $false
            }
        } elseif ($null -ne $current -and $line -match '^Connect\s*=\s*(.+)$') {
            $conn = $Matches[1].Trim().TrimEnd(';')
            if ($conn -match 'Srvr\s*=\s*"([^"]*)"') { $current.Server = $Matches[1]; $current.IsServer = $true }
            if ($conn -match 'Ref\s*=\s*"([^"]*)"')  { $current.Ref    = $Matches[1] }
            if ($conn -match 'File\s*=\s*"([^"]*)"') { $current.FilePath = $Matches[1] }
        }
    }
    if ($null -ne $current) { $bases.Add($current) }

    return @($bases | Where-Object { $_.Server -or $_.FilePath })
}

# ─────────────────────────────────────────────────────────────────────────────
# Шаг 5: Меню выбора базы (стрелки + Enter)
# ─────────────────────────────────────────────────────────────────────────────

function Show-InteractiveMenu {
    param([string]$Title, [string[]]$Items)

    if (-not $Items -or $Items.Count -eq 0) { return -1 }

    $selectedIdx = 0
    $count       = $Items.Count
    # Строк: заголовок + пустая + N элементов + пустая + подсказка = N + 4
    $menuHeight  = $count + 4

    Write-Host ''
    $topRow = [Console]::CursorTop

    # Резервируем место
    for ($i = 0; $i -lt $menuHeight; $i++) { Write-Host '' }

    $prevVisible = [Console]::CursorVisible
    [Console]::CursorVisible = $false

    function Redraw-Line {
        param([int]$Index, [bool]$Active)
        [Console]::SetCursorPosition(0, $topRow + 2 + $Index)
        if ($Active) {
            Write-Host ('  > ' + $Items[$Index]).PadRight([Console]::WindowWidth - 1) -ForegroundColor White
        } else {
            Write-Host ('    ' + $Items[$Index]).PadRight([Console]::WindowWidth - 1) -ForegroundColor DarkGray
        }
    }

    try {
        # Первоначальный рендер
        [Console]::SetCursorPosition(0, $topRow)
        Write-Host "  $Title" -ForegroundColor Cyan
        Write-Host ''
        for ($i = 0; $i -lt $count; $i++) {
            Redraw-Line -Index $i -Active ($i -eq $selectedIdx)
        }
        Write-Host ''
        Write-Host '  [Стрелки] навигация   [Enter] выбрать   [Esc] отмена'.PadRight([Console]::WindowWidth - 1) -ForegroundColor DarkGray

        while ($true) {
            $key  = [Console]::ReadKey($true)
            $prev = $selectedIdx

            switch ($key.Key) {
                'UpArrow'   { $selectedIdx = if ($selectedIdx -gt 0) { $selectedIdx - 1 } else { $count - 1 } }
                'DownArrow' { $selectedIdx = if ($selectedIdx -lt $count - 1) { $selectedIdx + 1 } else { 0 } }
                'Enter' {
                    [Console]::SetCursorPosition(0, $topRow + $menuHeight)
                    Write-Host ''
                    return $selectedIdx
                }
                'Escape' {
                    [Console]::SetCursorPosition(0, $topRow + $menuHeight)
                    Write-Host ''
                    return -1
                }
            }

            if ($selectedIdx -ne $prev) {
                Redraw-Line -Index $prev        -Active $false
                Redraw-Line -Index $selectedIdx -Active $true
            }
        }
    } finally {
        [Console]::CursorVisible = $prevVisible
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# Шаг 6: Временный .1c-devbase.bat
# ─────────────────────────────────────────────────────────────────────────────

function Write-TempDevBase {
    param(
        [string]$ProjectRoot,
        [pscustomobject]$Database,
        [string]$OnecExePath,
        [string]$AuthUser     = '',
        [string]$AuthPassword = ''
    )

    $devbasePath = Join-Path $ProjectRoot '.1c-devbase.bat'
    $backupPath  = Join-Path $ProjectRoot '.1c-devbase.bat.bak'

    $hadOriginal = Test-Path $devbasePath
    if ($hadOriginal) { Copy-Item $devbasePath $backupPath -Force }

    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add('@echo off')
    $lines.Add("set `"ONEC_PATH=$OnecExePath`"")

    if ($Database.IsServer) {
        $lines.Add("set `"ONEC_SERVER=$($Database.Server)`"")
        $lines.Add("set `"ONEC_BASE=$($Database.Ref)`"")
    } else {
        $lines.Add("set `"ONEC_FILEBASE_PATH=$($Database.FilePath)`"")
    }

    if ($AuthUser) {
        # Явные учётные данные пользователя 1С
        $lines.Add("set `"ONEC_USER=$AuthUser`"")
        $lines.Add("set `"ONEC_PASSWORD=$AuthPassword`"")
    }
    # иначе: ONEC_USER и ONEC_PASSWORD не задаются ->
    #         платформа 1С использует текущего пользователя Windows (доменная аутентификация)

    [System.IO.File]::WriteAllLines($devbasePath, $lines, [System.Text.Encoding]::ASCII)

    return [pscustomobject]@{
        DevBasePath = $devbasePath
        BackupPath  = $backupPath
        HadOriginal = $hadOriginal
    }
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
    } catch {
        Write-Warn "Не удалось восстановить .1c-devbase.bat: $_"
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# Шаг 7: Вызов load-config.bat (скилл 1c-batch)
# ─────────────────────────────────────────────────────────────────────────────

function Invoke-LoadConfig {
    param(
        [string]$WorkingDirectory,
        [string]$XmlDir,
        [string[]]$RelFiles,
        [switch]$SkipDbUpdate
    )

    $skillScript = Join-Path $HOME '.cursor\skills\1c-batch\scripts\load-config.bat'
    if (-not (Test-Path $skillScript)) {
        throw "Скрипт load-config.bat не найден: $skillScript"
    }

    $fileList = ($RelFiles | ForEach-Object { $_.Replace('/', '\') }) -join ','

    $batArgs = "`"$XmlDir`""
    if ($fileList)    { $batArgs += " `"$fileList`"" }
    if ($SkipDbUpdate) { $batArgs += ' skipdbupdate' }

    Write-Info "Команда: load-config.bat $batArgs"
    Write-Host ''

    $cmdLine = "/c `"`"$skillScript`" $batArgs`""
    $proc = Start-Process `
        -FilePath         'cmd.exe' `
        -ArgumentList     $cmdLine `
        -WorkingDirectory $WorkingDirectory `
        -Wait `
        -PassThru `
        -NoNewWindow

    return $proc.ExitCode
}

# ─────────────────────────────────────────────────────────────────────────────
# MAIN
# ─────────────────────────────────────────────────────────────────────────────

Clear-Host
Write-Banner

try {

# ── 1. Папка ─────────────────────────────────────────────────────────────────
Write-Step '1' 'Папка проекта'

$projectFolder = Select-ProjectFolder -InitialPath $Path
if (-not $projectFolder) {
    Write-Fail 'Папка не выбрана. Выход.'
    Exit-Script 1
}
Write-Ok "Папка: $projectFolder"

# ── Проверка git ──────────────────────────────────────────────────────────────
if (-not (Test-GitInstalled)) {
    Write-Fail 'git не найден в PATH. Установите Git for Windows.'
    Exit-Script 1
}

$gitRoot = Find-GitRoot -StartPath $projectFolder
if (-not $gitRoot) {
    Write-Fail 'Папка не является git-репозиторием и не находится внутри него.'
    Write-Info 'Убедитесь, что папка или одна из родительских содержит директорию .git'
    Exit-Script 1
}
if ($gitRoot -ne $projectFolder) {
    Write-Info "Git-корень: $gitRoot"
}

# Автоопределение корня XML-конфигурации 1С (где лежит Configuration.xml)
# Если пользователь выбрал корень репо, а не папку с XML — находим её сами
$xmlDir = Find-OnecXmlRoot -StartPath $projectFolder
if ($xmlDir) {
    if ($xmlDir -ne $projectFolder) {
        Write-Info "Корень конфигурации 1С: $xmlDir"
    }
} else {
    Write-Warn 'Configuration.xml не найден — убедитесь, что выбрана папка с XML-файлами 1С'
    $xmlDir = $projectFolder
}

# ── 2. Изменённые и новые файлы ───────────────────────────────────────────────
Write-Step '2' 'Изменённые и новые файлы (git diff + untracked)'

# Фильтр: только файлы внутри xmlDir (относительно gitRoot)
$subPathFilter = ''
if ($xmlDir -ne $gitRoot) {
    $subPathFilter = $xmlDir.Substring($gitRoot.Length).TrimStart('\', '/').Replace('\', '/')
}

try {
    [string[]]$changedFiles = @(Get-GitChangedFiles -GitRoot $gitRoot -SubPath $subPathFilter)
} catch {
    Write-Fail "Ошибка git: $_"
    Exit-Script 1
}

if ($changedFiles.Count -eq 0) {
    Write-Warn 'Незакоммиченных изменений и новых XML/BSL-файлов не обнаружено.'
    Write-Info "Проверьте 'git status' в папке: $gitRoot"
    Exit-Script 0
}

Write-Ok "Обнаружено файлов: $($changedFiles.Count)"
Write-Host ''
foreach ($f in $changedFiles) {
    Write-Host "      $f" -ForegroundColor White
}

if ($DryRun) {
    Write-Host ''
    Write-Warn 'Режим DryRun — загрузка не выполняется.'
    Exit-Script 0
}

# ── 3. Платформа 1С ───────────────────────────────────────────────────────────
Write-Step '3' 'Платформа 1С'

$onecExe = Find-1CExecutable
if (-not $onecExe) {
    Write-Fail '1cv8.exe не найден. Установите платформу 1С:Предприятие 8.3.'
    Exit-Script 1
}
Write-Ok "Найдена: $onecExe"

# ── 4. Выбор базы ─────────────────────────────────────────────────────────────
Write-Step '4' 'База 1С'

$bases = Get-IBasesList
if (-not $bases -or $bases.Count -eq 0) {
    $ibasesFile = Join-Path $env:APPDATA '1C\1CEStart\ibases.v8i'
    if (Test-Path $ibasesFile) {
        Write-Fail 'Список баз 1С пуст или не содержит распознанных записей.'
    } else {
        Write-Fail "Файл списка баз не найден: $ibasesFile"
    }
    Write-Info 'Откройте запускатор 1С:Предприятие и добавьте нужные базы.'
    Exit-Script 1
}

$menuLabels = @($bases | ForEach-Object {
    if ($_.IsServer) { "$($_.Name)   [Srvr=$($_.Server) / $($_.Ref)]" }
    else             { "$($_.Name)   [File=$($_.FilePath)]" }
})

$selectedIdx = Show-InteractiveMenu -Title 'Выберите базу 1С:' -Items $menuLabels
if ($selectedIdx -lt 0) {
    Write-Warn 'Выбор отменён. Выход.'
    Exit-Script 0
}

$selectedBase = $bases[$selectedIdx]
Write-Ok "База: $($selectedBase.Name)"

# ── 5. Подтверждение ──────────────────────────────────────────────────────────
Write-Step '5' 'Подтверждение'
Write-Host ''

if ($selectedBase.IsServer) {
    Write-Host "    База:     $($selectedBase.Name)   ($($selectedBase.Server) / $($selectedBase.Ref))" -ForegroundColor White
} else {
    Write-Host "    База:     $($selectedBase.Name)   ($($selectedBase.FilePath))" -ForegroundColor White
}

$authLabel = if ($User) { "Пользователь: $User" } else { 'Windows (доменная)' }
Write-Host "    Аутентиф: $authLabel" -ForegroundColor White
Write-Host "    Файлов:   $($changedFiles.Count)" -ForegroundColor White

if ($SkipDbUpdate) {
    Write-Host '    БД-update: пропустить' -ForegroundColor Yellow
}

Write-Host ''
$confirm = Read-Host '  Загрузить изменения? [Y/n]'
if ($confirm -and ($confirm -notmatch '^[YyДд]?$')) {
    Write-Warn 'Отменено.'
    Exit-Script 0
}

# ── 6. Загрузка ───────────────────────────────────────────────────────────────
Write-Step '6' 'Загрузка'

# Пути файлов относительно xmlDir
# git diff возвращает пути относительно gitRoot, убираем prefix subPathFilter
$relativeToXmlDir = @($changedFiles | ForEach-Object {
    if ($subPathFilter) { $_.Substring($subPathFilter.Length).TrimStart('/') }
    else                { $_ }
})

$devbaseState = $null
$loadSuccess  = $false

try {
    $devbaseState = Write-TempDevBase `
        -ProjectRoot  $gitRoot `
        -Database     $selectedBase `
        -OnecExePath  $onecExe `
        -AuthUser     $User `
        -AuthPassword $Password

    Write-Info 'Создан временный .1c-devbase.bat'

    $exitCode = Invoke-LoadConfig `
        -WorkingDirectory $gitRoot `
        -XmlDir           $xmlDir `
        -RelFiles         $relativeToXmlDir `
        -SkipDbUpdate:$SkipDbUpdate

    if ($exitCode -eq 0) {
        $loadSuccess = $true
        Write-Host ''
        Write-Ok 'Загрузка завершена успешно!'
    } else {
        Write-Host ''
        Write-Fail "Загрузка завершилась с ошибкой (код: $exitCode)"
        Write-Warn '.1c-devbase.bat сохранён для диагностики.'
    }
} catch {
    Write-Host ''
    Write-Fail "Ошибка при загрузке: $_"
    if ($devbaseState) {
        Write-Warn '.1c-devbase.bat сохранён для диагностики.'
    }
} finally {
    if ($loadSuccess -and $null -ne $devbaseState) {
        Restore-DevBase -State $devbaseState
        Write-Info '.1c-devbase.bat восстановлен.'
    }
}

} catch {
    # Перехват любых необработанных исключений — окно не закроется
    Write-Host ''
    Write-Fail "Непредвиденная ошибка: $_"
    Write-Info "Строка $($_.InvocationInfo.ScriptLineNumber): $($_.InvocationInfo.Line.Trim())"
}

Write-Host ''
Read-Host '  Нажмите Enter для выхода'
