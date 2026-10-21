# Usage: .\build.ps1 [-VerboseBuild] [path/to/file.tex]
# PDF goes to .build/. Optional: $env:LATEXMK_BIN = path to latexmk
# Quiet by default. Pass -VerboseBuild, -v, or --verbose to stream latexmk output.

function Get-BuildSelfName {
    $path = $PSCommandPath
    if ([string]::IsNullOrEmpty($path)) {
        $path = $MyInvocation.PSCommandPath
    }
    if ([string]::IsNullOrEmpty($path)) {
        return 'build.ps1'
    }
    return (Split-Path -Leaf $path)
}

function Get-BuildUsage {
    return "Usage: .\$(Get-BuildSelfName) [-VerboseBuild] [filename.tex]"
}

function Get-BuildPathSep {
    if ([System.Environment]::OSVersion.Platform -eq 'Win32NT') {
        return ';'
    }
    return ':'
}

function Get-BuildScriptDir {
    if (-not [string]::IsNullOrEmpty($PSScriptRoot)) {
        return $PSScriptRoot
    }
    $path = $PSCommandPath
    if ([string]::IsNullOrEmpty($path)) {
        $path = $MyInvocation.PSCommandPath
    }
    return (Split-Path -Parent $path)
}

function Get-BuildRcFile {
    param([string]$Root)
    $hidden = Join-Path $Root '.latexmkrc'
    $plain = Join-Path $Root 'latexmkrc'
    if (Test-Path $hidden) { return $hidden }
    if (Test-Path $plain) { return $plain }
    return $null
}

function Add-BuildSearchPath {
    param([string]$VarName, [string]$Root)
    $sep = Get-BuildPathSep
    $current = [Environment]::GetEnvironmentVariable($VarName)
    if ([string]::IsNullOrEmpty($current)) {
        [Environment]::SetEnvironmentVariable($VarName, "$Root$sep")
    } else {
        [Environment]::SetEnvironmentVariable($VarName, "$Root$sep$current")
    }
}

function Add-BuildTexToPath {
    $extra = [System.Collections.Generic.List[string]]::new()
    if (Test-Path '/Library/TeX/texbin') { $extra.Add('/Library/TeX/texbin') }
    if (Test-Path '/usr/local/texlive') {
        Get-ChildItem '/usr/local/texlive/*/bin/*' -Directory -ErrorAction SilentlyContinue | ForEach-Object { $extra.Add($_.FullName) }
    }
    $miktex = $null
    if ($env:LOCALAPPDATA) {
        $miktex = Join-Path $env:LOCALAPPDATA 'Programs\MiKTeX\miktex\bin\x64'
    }
    if ((-not $miktex -or -not (Test-Path -LiteralPath $miktex)) -and $env:USERPROFILE) {
        $miktex = Join-Path $env:USERPROFILE 'AppData\Local\Programs\MiKTeX\miktex\bin\x64'
    }
    if ($miktex -and (Test-Path -LiteralPath $miktex)) { $extra.Add($miktex) }
    $sep = Get-BuildPathSep
    foreach ($p in $extra) {
        $env:PATH = "$p$sep$env:PATH"
    }
}

function Resolve-BuildLatexmk {
    if ($env:LATEXMK_BIN) {
        if (Test-Path $env:LATEXMK_BIN) {
            return $env:LATEXMK_BIN
        }
        $cmd = Get-Command $env:LATEXMK_BIN -ErrorAction SilentlyContinue
        if ($cmd) { return $cmd.Source }
        Write-Host "Error: LATEXMK_BIN is set but not executable: $($env:LATEXMK_BIN)" -ForegroundColor Red
        return $null
    }
    $found = Get-Command latexmk -ErrorAction SilentlyContinue
    if ($found) { return $found.Source }
    Add-BuildTexToPath
    $found = Get-Command latexmk -ErrorAction SilentlyContinue
    if ($found) { return $found.Source }
    Write-Host "Error: latexmk is not installed or not on PATH" -ForegroundColor Red
    Write-Host "  MacTeX: /Library/TeX/texbin   TeX Live: /usr/local/texlive/*/bin/*" -ForegroundColor DarkGray
    Write-Host "  Windows: install MiKTeX or TeX Live and reopen the terminal" -ForegroundColor DarkGray
    return $null
}

function Get-BuildPatternCount {
    param([string]$Pattern, [string]$File)
    if (-not (Test-Path $File)) { return 0 }
    $hits = @(Select-String -Path $File -Pattern $Pattern -ErrorAction SilentlyContinue)
    return $hits.Count
}

function Get-BuildPdfSize {
    param([string]$Pdf)
    if (-not (Test-Path -LiteralPath $Pdf -PathType Leaf)) { return '' }
    $sizeBytes = (Get-Item -LiteralPath $Pdf -Force).Length
    if ($sizeBytes -lt 1024) { return "$sizeBytes" }
    if ($sizeBytes -lt 1048576) { return "$([math]::Floor($sizeBytes / 1024))K" }
    $sizeMb = [math]::Round($sizeBytes / 1MB, 1)
    $text = "$sizeMb" + 'M'
    return ($text -replace '\.0M$', 'M')
}

function Get-BuildPageCount {
    param([string]$Pdf)
    $pdfinfo = Get-Command pdfinfo -ErrorAction SilentlyContinue
    if ($pdfinfo) {
        $line = & pdfinfo $Pdf 2>$null | Select-String '^Pages:'
        if ($line) { return ($line.ToString() -split '\s+')[1] }
        return ''
    }
    $pdftk = Get-Command pdftk -ErrorAction SilentlyContinue
    if ($pdftk) {
        $line = & pdftk $Pdf dump_data 2>$null | Select-String 'NumberOfPages'
        if ($line) { return ($line.ToString() -split '\s+')[1] }
    }
    return ''
}

function Test-BuildInteractive {
    if ($env:BUILD_NONINTERACTIVE -eq '1') { return $false }
    try {
        return [Environment]::UserInteractive -and -not [Console]::IsInputRedirected
    } catch {
        return $false
    }
}

function Get-BuildTexChoice {
    $texFiles = @(
        Get-ChildItem -Path . -Filter '*.tex' -File |
            Where-Object { -not $_.Name.StartsWith('.') } |
            Sort-Object Name
    )
    if ($texFiles.Count -eq 0) {
        Write-Host "No .tex files in this directory. $(Get-BuildUsage)" -ForegroundColor Red
        return @{ Status = 1; File = '' }
    }
    if ($texFiles.Count -eq 1) {
        return @{ Status = 0; File = $texFiles[0].Name }
    }
    if (-not (Test-BuildInteractive)) {
        Write-Host "Several .tex files in this directory. Pass one:" -ForegroundColor Red
        foreach ($f in $texFiles) { Write-Host "  $($f.Name)" }
        return @{ Status = 1; File = '' }
    }
    Write-Host ""
    Write-Host "  Select a .tex file" -ForegroundColor Cyan
    Write-Host ""
    for ($i = 0; $i -lt $texFiles.Count; $i++) {
        Write-Host "  [$($i + 1)] " -NoNewline -ForegroundColor DarkGray
        Write-Host $texFiles[$i].Name -ForegroundColor Cyan
    }
    Write-Host ""
    $selection = Read-Host "  Select (1-$($texFiles.Count)) or Enter to cancel"
    if ($selection -eq '' -or $selection -eq 'q' -or $selection -eq 'Q') {
        Write-Host "Build cancelled."
        return @{ Status = 2; File = '' }
    }
    $selectedIndex = 0
    if (-not [int]::TryParse($selection, [ref]$selectedIndex)) {
        Write-Host "Invalid selection. Build cancelled." -ForegroundColor Red
        return @{ Status = 1; File = '' }
    }
    $selectedIndex = $selectedIndex - 1
    if ($selectedIndex -ge 0 -and $selectedIndex -lt $texFiles.Count) {
        return @{ Status = 0; File = $texFiles[$selectedIndex].Name }
    }
    Write-Host "Invalid selection. Build cancelled." -ForegroundColor Red
    return @{ Status = 1; File = '' }
}

function Get-BuildWarnErrorCounts {
    param([string]$LogPath)
    $errorCount = Get-BuildPatternCount -Pattern '^!' -File $LogPath
    $warningCount = 0
    foreach ($pattern in @(
            '^LaTeX Warning:',
            '^Package .* Warning:',
            '^Overfull',
            '^Underfull',
            '^Font shape',
            '^Missing character'
        )) {
        $warningCount += Get-BuildPatternCount -Pattern $pattern -File $LogPath
    }
    return @{ Errors = $errorCount; Warnings = $warningCount }
}

function Write-BuildSuccess {
    param($OriginalDir, $PdfPath, $LogPath, $BaseName, $Elapsed)
    $pdfSize = Get-BuildPdfSize $PdfPath
    $pageCount = Get-BuildPageCount $PdfPath
    Write-Host ""
    Write-Host "Success" -ForegroundColor Green
    $summary = "$BaseName.pdf"
    if ($pageCount) { $summary += " · $pageCount page(s)" }
    if ($pdfSize) { $summary += " · $pdfSize" }
    if ($Elapsed -gt 0) { $summary += " · ${Elapsed}s" }
    Write-Host "  $summary" -ForegroundColor DarkGray
    Write-Host ""
    $originalDirStr = "$OriginalDir"
    if ($PdfPath.StartsWith($originalDirStr, [System.StringComparison]::OrdinalIgnoreCase)) {
        $displayPath = $PdfPath.Substring($originalDirStr.Length).TrimStart('\', '/')
    } else {
        $displayPath = "$BaseName.pdf (in .build/)"
    }
    Write-Host "  Output:" -ForegroundColor White
    Write-Host "    File:   $displayPath" -ForegroundColor DarkGray
    if ($pageCount) { Write-Host ("    {0,-7} {1}" -f "Pages:", $pageCount) -ForegroundColor DarkGray }
    if ($pdfSize) { Write-Host ("    {0,-7} {1}" -f "Size:", $pdfSize) -ForegroundColor DarkGray }
    if ($Elapsed -gt 0) { Write-Host ("    {0,-7} {1}" -f "Time:", "${Elapsed}s") -ForegroundColor DarkGray }
    if (Test-Path $LogPath) {
        $counts = Get-BuildWarnErrorCounts $LogPath
        if ($counts.Errors -gt 0 -or $counts.Warnings -gt 0) {
            Write-Host ""
            Write-Host "  Issues:" -ForegroundColor Yellow
            if ($counts.Errors -gt 0) { Write-Host "    Errors:   $($counts.Errors)" -ForegroundColor Red }
            if ($counts.Warnings -gt 0) { Write-Host "    Warnings: $($counts.Warnings)" -ForegroundColor Yellow }
            Write-Host "    Log:     $LogPath" -ForegroundColor DarkGray
        }
    }
}

function Write-BuildLogExcerpt {
    param([string]$LogPath, [int]$MaxLines = 8)
    if (-not (Test-Path $LogPath)) { return $false }
    $lines = @(Get-Content -Path $LogPath -ErrorAction SilentlyContinue)
    if ($lines.Count -eq 0) { return $false }
    $start = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^!') {
            $start = $i
            break
        }
    }
    if ($start -lt 0) { return $false }
    Write-Host "  Log excerpt:" -ForegroundColor White
    $printed = 0
    for ($i = $start; $i -lt $lines.Count -and $printed -lt $MaxLines; $i++) {
        $line = $lines[$i]
        if ($printed -gt 2 -and ($line -match '^\s*$' -or $line -match '^\s*\*+' -or $line -match '^\[')) {
            break
        }
        Write-Host "    $line" -ForegroundColor DarkGray
        $printed++
    }
    return $true
}

function Write-BuildFailure {
    param([string]$LogPath, [string]$CapturePath = '')
    Write-Host ""
    Write-Host "Compilation Failed" -ForegroundColor Red
    Write-Host ""
    if (Test-Path $LogPath) {
        $counts = Get-BuildWarnErrorCounts $LogPath
        Write-Host "  Issues Found:" -ForegroundColor White
        if ($counts.Errors -gt 0) { Write-Host "    Errors:   $($counts.Errors)" -ForegroundColor Red }
        if ($counts.Warnings -gt 0) { Write-Host "    Warnings: $($counts.Warnings)" -ForegroundColor Yellow }
        Write-Host "    Log:      $LogPath" -ForegroundColor DarkGray
        Write-Host ""
        $printedExcerpt = Write-BuildLogExcerpt $LogPath
        $captureText = ''
        if ($CapturePath -and (Test-Path $CapturePath)) {
            $captureText = Get-Content -Path $CapturePath -Raw -ErrorAction SilentlyContinue
        }
        if ((-not $printedExcerpt -or ($captureText -match 'pdflatex not found')) -and $captureText) {
            Write-Host "  latexmk output:" -ForegroundColor White
            Get-Content -Path $CapturePath -TotalCount 40 -ErrorAction SilentlyContinue | ForEach-Object {
                Write-Host "    $_" -ForegroundColor DarkGray
            }
        }
    } else {
        Write-Host "  Log file not found: $LogPath" -ForegroundColor DarkGray
        if ($CapturePath -and (Test-Path $CapturePath)) {
            Write-Host ""
            Write-Host "  latexmk output:" -ForegroundColor White
            Get-Content -Path $CapturePath -TotalCount 40 -ErrorAction SilentlyContinue | ForEach-Object {
                Write-Host "    $_" -ForegroundColor DarkGray
            }
        }
    }
    Write-Host ""
    Write-Host "  Re-run with -VerboseBuild to stream latexmk." -ForegroundColor DarkGray
    Write-Host ""
}

function Invoke-BuildLatexmk {
    param(
        [string]$Bin,
        [string[]]$LatexmkArgs,
        [string]$TexFileName,
        [string]$CapturePath,
        [bool]$ShowOutput
    )
    $allArgs = @($LatexmkArgs) + @($TexFileName)
    if ($ShowOutput) {
        if ($Bin -like '*.ps1') {
            & powershell.exe -NoProfile -File $Bin -- @allArgs
            if ($null -eq $LASTEXITCODE) { return 1 }
            return $LASTEXITCODE
        }
        # Out-Host shows latexmk output without mixing it into the exit code.
        & $Bin @allArgs | Out-Host
        $exitCode = $LASTEXITCODE
        if ($null -eq $exitCode) { return 1 }
        return $exitCode
    }
    if ($Bin -like '*.ps1') {
        & powershell.exe -NoProfile -File $Bin -- @allArgs *> $CapturePath
        if ($null -eq $LASTEXITCODE) { return 1 }
        return $LASTEXITCODE
    }
    & $Bin @allArgs *> $CapturePath
    if ($null -eq $LASTEXITCODE) { return 1 }
    return $LASTEXITCODE
}

function Invoke-BuildMain {
    param(
        [string]$TexFile = '',
        [bool]$ShowLatexmk = $false
    )
    $oldTexinputs = $env:TEXINPUTS
    $oldBibinputs = $env:BIBINPUTS
    $oldBstinputs = $env:BSTINPUTS
    $originalDir = Get-Location
    try {
        if ([string]::IsNullOrEmpty($TexFile)) {
            $pick = Get-BuildTexChoice
            if ($pick.Status -eq 2) { return 0 }
            if ($pick.Status -ne 0) { return 1 }
            $TexFile = $pick.File
        }
        if ([string]::IsNullOrEmpty($TexFile) -or -not (Test-Path -LiteralPath $TexFile -PathType Leaf)) {
            Write-Host "Error: No .tex file found. $(Get-BuildUsage)" -ForegroundColor Red
            return 1
        }
        if ($TexFile -notlike '*.tex') {
            Write-Host "Error: File must have .tex extension: $TexFile" -ForegroundColor Red
            return 1
        }

        $latexmkBin = Resolve-BuildLatexmk
        if (-not $latexmkBin) { return 1 }
        if (-not (Get-Command pdflatex -ErrorAction SilentlyContinue)) {
            Write-Host "Error: pdflatex not found" -ForegroundColor Red
            return 1
        }

        $texItem = Get-Item -LiteralPath $TexFile -Force
        if ($texItem.LinkType) {
            $texTarget = $texItem.ResolveLinkTarget($true)
            if ($texTarget) { $texItem = $texTarget }
        }
        $texFileAbs = $texItem.FullName
        $texDir = Split-Path -Parent $texFileAbs
        $baseName = [System.IO.Path]::GetFileNameWithoutExtension($texFileAbs)
        $buildDir = Join-Path $texDir '.build'
        $texFileName = Split-Path -Leaf $texFileAbs
        New-Item -ItemType Directory -Force -Path $buildDir | Out-Null

        Add-BuildSearchPath 'TEXINPUTS' $texDir
        Add-BuildSearchPath 'BIBINPUTS' $texDir
        Add-BuildSearchPath 'BSTINPUTS' $texDir

        $scriptDir = Get-BuildScriptDir
        Add-BuildSearchPath 'TEXINPUTS' $scriptDir
        Add-BuildSearchPath 'BIBINPUTS' $scriptDir
        Add-BuildSearchPath 'BSTINPUTS' $scriptDir

        $latexmkArgs = @(
            '-pdf',
            '-interaction=nonstopmode',
            '-synctex=1',
            '-silent',
            "-output-directory=$buildDir"
        )
        $rcFile = Get-BuildRcFile $scriptDir
        if ($rcFile) {
            $latexmkArgs += @('-r', $rcFile)
        }

        Set-Location $texDir
        $separator = "------------------------------------------------------------------------------"
        Write-Host ""
        Write-Host $separator -ForegroundColor Cyan
        Write-Host "  Compiling: " -NoNewline -ForegroundColor Cyan
        Write-Host $texFileName -ForegroundColor Cyan
        Write-Host $separator -ForegroundColor Cyan
        if ($ShowLatexmk) {
            Write-Host "  [latexmk] $latexmkBin" -ForegroundColor DarkGray
        }

        $capturePath = Join-Path ([System.IO.Path]::GetTempPath()) ("latexmk-" + [guid]::NewGuid().ToString('N') + ".out")
        $startTime = Get-Date
        $compileStatus = Invoke-BuildLatexmk -Bin $latexmkBin -LatexmkArgs $latexmkArgs -TexFileName $texFileName -CapturePath $capturePath -ShowOutput $ShowLatexmk
        $elapsed = [math]::Floor(((Get-Date) - $startTime).TotalSeconds)
        $pdfPath = Join-Path $buildDir "$baseName.pdf"
        $logPath = Join-Path $buildDir "$baseName.log"

        if ((Test-Path $pdfPath) -and ($compileStatus -eq 0)) {
            Write-BuildSuccess $originalDir.Path $pdfPath $logPath $baseName $elapsed
            return 0
        }
        Write-BuildFailure $logPath $capturePath
        return 1
    } finally {
        Set-Location $originalDir
        $env:TEXINPUTS = $oldTexinputs
        $env:BIBINPUTS = $oldBibinputs
        $env:BSTINPUTS = $oldBstinputs
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    $showLatexmk = $false
    $texArg = ''
    $endOfOptions = $false
    foreach ($cliArg in @($args)) {
        $text = [string]$cliArg
        if (-not $endOfOptions -and $text -eq '--') {
            $endOfOptions = $true
            continue
        }
        if (-not $endOfOptions -and ($text -in @('-v', '--verbose', '-Verbose', '-VerboseBuild'))) {
            $showLatexmk = $true
            continue
        }
        if (-not $endOfOptions -and ($text -in @('-h', '--help'))) {
            Write-Host (Get-BuildUsage)
            exit 0
        }
        if (-not $endOfOptions -and $text.StartsWith('-')) {
            Write-Host "Error: Unknown option: $text" -ForegroundColor Red
            Write-Host (Get-BuildUsage)
            exit 1
        }
        $texArg = $text
    }
    exit (Invoke-BuildMain -TexFile $texArg -ShowLatexmk $showLatexmk)
}
