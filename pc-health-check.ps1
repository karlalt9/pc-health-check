#Requires -Version 5.1

<#
.SYNOPSIS
    电脑体检助手 - 一键检查 Windows 电脑的硬件、磁盘和安全状态

.DESCRIPTION
    检查系统信息、处理器、内存、磁盘空间、硬盘类型、防火墙、病毒防护和待重启状态,
    输出一份中文体检报告,并可保存为文本或 JSON 文件。

    实现上优先使用注册表和 .NET 接口,必要时才调用 CIM/WMI,
    因此在普通用户权限下也能跑出结果,不需要安装 Python 或其他软件。

.PARAMETER OutputPath
    报告保存路径,默认为脚本目录下的 reports 文件夹

.PARAMETER Json
    在保存文本报告的同时,再导出一份 JSON

.PARAMETER NoFile
    只在屏幕上显示,不保存文件

.EXAMPLE
    .\pc-health-check.ps1

.EXAMPLE
    .\pc-health-check.ps1 -Json

.EXAMPLE
    .\pc-health-check.ps1 -OutputPath D:\report\checkup.txt

.NOTES
    作者: 余柏润
    许可: MIT
#>

[CmdletBinding()]
param(
    [string]$OutputPath,
    [switch]$Json,
    [switch]$NoFile
)

Set-StrictMode -Version 2.0

$script:Report     = New-Object System.Collections.ArrayList
$script:Findings   = New-Object System.Collections.ArrayList
$script:Result     = [ordered]@{}
$script:ReadIssues = New-Object System.Collections.ArrayList

# 直接调用 Win32 API 读取内存和运行时长。
# 相比 WMI,这种方式不需要管理员权限,在受限环境下也能拿到数据。
$script:Win32Ready = $false
try {
    Add-Type -ErrorAction Stop -TypeDefinition @"
using System;
using System.Runtime.InteropServices;

public class PcHealthWin32
{
    [StructLayout(LayoutKind.Sequential)]
    public struct MEMORYSTATUSEX
    {
        public uint dwLength;
        public uint dwMemoryLoad;
        public ulong ullTotalPhys;
        public ulong ullAvailPhys;
        public ulong ullTotalPageFile;
        public ulong ullAvailPageFile;
        public ulong ullTotalVirtual;
        public ulong ullAvailVirtual;
        public ulong ullAvailExtendedVirtual;
    }

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool GlobalMemoryStatusEx(ref MEMORYSTATUSEX lpBuffer);

    [DllImport("kernel32.dll")]
    public static extern ulong GetTickCount64();
}
"@
    $script:Win32Ready = $true
}
catch {
    $script:Win32Ready = $false
}

function Get-Win32Memory {
    if (-not $script:Win32Ready) { return $null }
    try {
        $status = New-Object PcHealthWin32+MEMORYSTATUSEX
        $status.dwLength = [System.Runtime.InteropServices.Marshal]::SizeOf($status)
        if ([PcHealthWin32]::GlobalMemoryStatusEx([ref]$status)) {
            return [pscustomobject]@{
                TotalBytes     = [double]$status.ullTotalPhys
                AvailableBytes = [double]$status.ullAvailPhys
                LoadPercent    = [double]$status.dwMemoryLoad
            }
        }
    }
    catch { }
    return $null
}

function Get-SystemUptime {
    if (-not $script:Win32Ready) { return $null }
    try {
        $ms = [double][PcHealthWin32]::GetTickCount64()
        if ($ms -gt 0) { return [TimeSpan]::FromMilliseconds($ms) }
    }
    catch { }
    return $null
}

function Write-Section {
    param([string]$Title)
    Write-Host ""
    Write-Host ("[{0}]" -f $Title) -ForegroundColor Cyan
    [void]$script:Report.Add("")
    [void]$script:Report.Add("[$Title]")
}

function Write-Item {
    param([string]$Label, [string]$Value, [string]$Color = "Gray")
    # 中文在控制台占两个字符宽,这里按显示宽度补空格,保证冒号后的内容对齐
    $width = 0
    foreach ($ch in $Label.ToCharArray()) {
        if ([int][char]$ch -gt 127) { $width += 2 } else { $width += 1 }
    }
    $pad = [Math]::Max(2, 16 - $width)
    $line = "  " + $Label + (" " * $pad) + $Value
    Write-Host $line -ForegroundColor $Color
    [void]$script:Report.Add($line)
}

function Add-Finding {
    param([string]$Level, [string]$Message)
    [void]$script:Findings.Add([pscustomobject]@{ Level = $Level; Message = $Message })
}

function Add-ReadIssue {
    param([string]$What)
    [void]$script:ReadIssues.Add($What)
}

function Get-OrNull {
    param([scriptblock]$Action)
    try { return & $Action } catch { return $null }
}

function Get-RegistryValue {
    param([string]$Path, [string]$Name)
    try {
        $item = Get-ItemProperty -Path $Path -Name $Name -ErrorAction Stop
        return $item.$Name
    }
    catch {
        return $null
    }
}

function Format-Size {
    param([double]$Bytes)
    if ($Bytes -ge 1GB) { return ("{0:N1} GB" -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ("{0:N1} MB" -f ($Bytes / 1MB)) }
    return ("{0:N0} KB" -f ($Bytes / 1KB))
}

Write-Host ""
Write-Host "==================================================" -ForegroundColor DarkCyan
Write-Host "  电脑体检助手  PC Health Check" -ForegroundColor White
Write-Host "  正在检查,请稍候..." -ForegroundColor DarkGray
Write-Host "==================================================" -ForegroundColor DarkCyan

$now = Get-Date
[void]$script:Report.Add("电脑体检报告")
[void]$script:Report.Add("生成时间: " + $now.ToString("yyyy-MM-dd HH:mm:ss"))

# ---------- 系统信息 ----------
Write-Section "系统信息"

$computerName = $env:COMPUTERNAME
$userName = $env:USERNAME
$arch = $env:PROCESSOR_ARCHITECTURE

$cvPath = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion"
$productName = Get-RegistryValue -Path $cvPath -Name "ProductName"
$displayVersion = Get-RegistryValue -Path $cvPath -Name "DisplayVersion"
$buildNumber = Get-RegistryValue -Path $cvPath -Name "CurrentBuildNumber"

if ($productName) {
    if ($buildNumber -and [int]$buildNumber -ge 22000) {
        $productName = $productName -replace "Windows 10", "Windows 11"
    }
    if ($displayVersion) { $osName = "$productName $displayVersion" } else { $osName = $productName }
    if ($buildNumber) { $osName = "$osName (内部版本 $buildNumber)" }
}
else {
    $osName = [System.Environment]::OSVersion.VersionString
    Add-ReadIssue "操作系统名称"
}

$uptime = $null
$span = Get-SystemUptime
$osCim = Get-OrNull { Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop }
if (-not $span -and $osCim -and $osCim.LastBootUpTime) {
    $span = $now - $osCim.LastBootUpTime
}
if ($span) {
    $uptime = "{0} 天 {1} 小时 {2} 分钟" -f $span.Days, $span.Hours, $span.Minutes
}
else {
    $uptime = "无法读取"
    Add-ReadIssue "系统运行时长"
}

Write-Item "计算机名" $computerName
Write-Item "当前用户" $userName
Write-Item "操作系统" $osName
Write-Item "系统架构" $arch
Write-Item "已运行" $uptime
$script:Result["computer"] = @{
    name = $computerName; user = $userName; os = $osName
    architecture = $arch; uptime = $uptime
}

# ---------- 处理器 ----------
Write-Section "处理器"

$cpuPath = "HKLM:\HARDWARE\DESCRIPTION\System\CentralProcessor\0"
$cpuName = Get-RegistryValue -Path $cpuPath -Name "ProcessorNameString"
if (-not $cpuName) {
    $cpuName = $env:PROCESSOR_IDENTIFIER
    if (-not $cpuName) {
        $cpuName = "无法读取"
        Add-ReadIssue "处理器型号"
    }
}
else {
    $cpuName = $cpuName.Trim()
}

$threads = $env:NUMBER_OF_PROCESSORS
$cores = $null
$cpuLoad = $null
$cpuCim = Get-OrNull { Get-CimInstance -ClassName Win32_Processor -ErrorAction Stop | Select-Object -First 1 }
if ($cpuCim) {
    if ($cpuCim.NumberOfCores) { $cores = $cpuCim.NumberOfCores }
    if ($null -ne $cpuCim.LoadPercentage) { $cpuLoad = $cpuCim.LoadPercentage }
}

Write-Item "型号" $cpuName
if ($cores) {
    Write-Item "核心/线程" ("{0} 核 / {1} 线程" -f $cores, $threads)
}
else {
    Write-Item "逻辑处理器" ("{0} 个" -f $threads)
}
if ($null -ne $cpuLoad) {
    Write-Item "当前负载" ("{0}%" -f $cpuLoad)
}

$script:Result["cpu"] = @{ name = $cpuName; cores = $cores; threads = $threads; load = $cpuLoad }

if ($null -ne $cpuLoad -and [int]$cpuLoad -ge 85) {
    Add-Finding -Level "警告" -Message ("处理器当前负载 {0}%,检查一下是否有程序占用过高" -f $cpuLoad)
}

# ---------- 内存 ----------
Write-Section "内存"

$totalBytes = $null
$freeBytes = $null

# 第一选择:Win32 API(不需要管理员权限)
$mem = Get-Win32Memory
if ($mem) {
    $totalBytes = $mem.TotalBytes
    $freeBytes = $mem.AvailableBytes
}

# 第二选择:WMI
if (-not $totalBytes -and $osCim) {
    try {
        $totalBytes = [double]$osCim.TotalVisibleMemorySize * 1KB
        $freeBytes = [double]$osCim.FreePhysicalMemory * 1KB
    }
    catch { }
}

if (-not $totalBytes) {
    $cs = Get-OrNull { Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop }
    if ($cs -and $cs.TotalPhysicalMemory) {
        $totalBytes = [double]$cs.TotalPhysicalMemory
        $available = Get-OrNull {
            (Get-Counter -Counter "\Memory\Available MBytes" -ErrorAction Stop).CounterSamples[0].CookedValue
        }
        if ($available) { $freeBytes = [double]$available * 1MB }
    }
}

if ($totalBytes -and $freeBytes) {
    $usedPercent = [math]::Round((($totalBytes - $freeBytes) / $totalBytes) * 100, 1)
    Write-Item "总容量" (Format-Size $totalBytes)
    Write-Item "可用" (Format-Size $freeBytes)
    $memColor = if ($usedPercent -ge 85) { "Yellow" } else { "Gray" }
    Write-Item "使用率" ("{0}%" -f $usedPercent) $memColor
    $script:Result["memory"] = @{
        total_gb = [math]::Round($totalBytes / 1GB, 1)
        free_gb = [math]::Round($freeBytes / 1GB, 1)
        used_percent = $usedPercent
    }
    if ($usedPercent -ge 85) {
        Add-Finding -Level "警告" -Message ("内存使用率 {0}%,关掉不用的程序,或考虑加内存条" -f $usedPercent)
    }
    else {
        Add-Finding -Level "正常" -Message ("内存使用率 {0}%,状态良好" -f $usedPercent)
    }
}
else {
    Write-Item "状态" "无法读取内存信息" "DarkGray"
    Add-ReadIssue "内存信息"
}

# ---------- 磁盘 ----------
Write-Section "磁盘空间"

$diskResult = @()
$drives = @()
try {
    $drives = [System.IO.DriveInfo]::GetDrives() | Where-Object { $_.DriveType -eq "Fixed" -and $_.IsReady }
}
catch { }

foreach ($drive in $drives) {
    try {
        $size = [double]$drive.TotalSize
        $free = [double]$drive.AvailableFreeSpace
        if ($size -le 0) { continue }
        $usedPercent = [math]::Round((($size - $free) / $size) * 100, 1)
        $freeGb = $free / 1GB
        $label = $drive.Name.TrimEnd("\")
        $line = "{0} 总容量 {1,-10} 可用 {2,-10} 已用 {3}%" -f $label, (Format-Size $size), (Format-Size $free), $usedPercent
        $color = "Gray"
        if ($usedPercent -ge 85 -or $freeGb -lt 20) { $color = "Yellow" }
        Write-Host ("  " + $line) -ForegroundColor $color
        [void]$script:Report.Add("  " + $line)
        $diskResult += @{
            drive = $label
            total_gb = [math]::Round($size / 1GB, 1)
            free_gb = [math]::Round($freeGb, 1)
            used_percent = $usedPercent
        }

        if ($usedPercent -ge 85) {
            Add-Finding -Level "警告" -Message ("{0} 盘已用 {1}%,清理一下临时文件和不用的软件" -f $label, $usedPercent)
        }
        elseif ($freeGb -lt 20) {
            Add-Finding -Level "注意" -Message ("{0} 盘只剩 {1:N1} GB,低于 20 GB 建议清理" -f $label, $freeGb)
        }
    }
    catch { }
}

if ($diskResult.Count -eq 0) {
    Write-Item "状态" "无法读取磁盘信息" "DarkGray"
    Add-ReadIssue "磁盘信息"
}
$script:Result["disks"] = $diskResult

# ---------- 硬盘类型 ----------
Write-Section "硬盘类型"

$physicalDisks = @()
$wmiDisks = @()
try {
    $physicalDisks = @(Get-PhysicalDisk -ErrorAction Stop | Select-Object -First 3)
}
catch {
    try {
        $wmiDisks = @(Get-CimInstance -ClassName Win32_DiskDrive -ErrorAction Stop | Select-Object -First 3)
    }
    catch {
        $wmiDisks = @()
    }
}

if ($physicalDisks.Count -gt 0) {
    foreach ($pd in $physicalDisks) {
        $media = switch ($pd.MediaType) {
            "SSD" { "固态硬盘 SSD" }
            "HDD" { "机械硬盘 HDD" }
            default { "$($pd.MediaType)" }
        }
        Write-Item $pd.FriendlyName ("{0}  {1}" -f $media, (Format-Size $pd.Size))
    }
    $isSsd = @($physicalDisks | Where-Object { $_.MediaType -eq "SSD" }).Count -gt 0
    if (-not $isSsd) {
        Add-Finding -Level "注意" -Message "没检测到固态硬盘,换成 SSD 能明显加快开机和软件启动"
    }
}
elseif ($wmiDisks.Count -gt 0) {
    foreach ($wd in $wmiDisks) {
        Write-Item $wd.Model (Format-Size $wd.Size)
    }
}
else {
    Write-Item "状态" "无法读取硬盘型号(可以试试以管理员身份运行)" "DarkGray"
}

# ---------- 安全状态 ----------
Write-Section "安全状态"

$firewallStates = @()
$profiles = Get-OrNull { Get-NetFirewallProfile -ErrorAction Stop }
if ($profiles) {
    foreach ($p in $profiles) {
        $label = switch ($p.Name) {
            "Domain" { "域网络" }
            "Private" { "专用网络" }
            "Public" { "公用网络" }
            default { "$($p.Name)" }
        }
        $firewallStates += [pscustomobject]@{ Name = $label; Enabled = [bool]$p.Enabled }
    }
}
else {
    # 降级方案:直接读注册表,普通权限也能读到
    $fwPath = "HKLM:\SYSTEM\CurrentControlSet\Services\SharedAccess\Parameters\FirewallPolicy"
    foreach ($item in @(
            @{ Key = "DomainProfile"; Label = "域网络" },
            @{ Key = "StandardProfile"; Label = "专用网络" },
            @{ Key = "PublicProfile"; Label = "公用网络" })) {
        $value = Get-RegistryValue -Path "$fwPath\$($item.Key)" -Name "EnableFirewall"
        if ($null -ne $value) {
            $firewallStates += [pscustomobject]@{ Name = $item.Label; Enabled = ([int]$value -eq 1) }
        }
    }
}

if ($firewallStates.Count -gt 0) {
    $disabled = @($firewallStates | Where-Object { -not $_.Enabled })
    if ($disabled.Count -eq 0) {
        Write-Item "防火墙" "全部配置文件已开启" "Green"
    }
    else {
        Write-Item "防火墙" ("以下配置未开启: " + (($disabled | ForEach-Object { $_.Name }) -join ", ")) "Yellow"
        Add-Finding -Level "警告" -Message "Windows 防火墙没有全部开启"
    }
}
else {
    Write-Item "防火墙" "无法读取状态" "DarkGray"
    Add-ReadIssue "防火墙状态"
}

$defender = Get-OrNull { Get-MpComputerStatus -ErrorAction Stop }
if ($defender) {
    if ($defender.RealTimeProtectionEnabled) {
        Write-Item "病毒防护" "实时保护已开启" "Green"
    }
    else {
        Write-Item "病毒防护" "实时保护未开启,建议马上打开" "Yellow"
        Add-Finding -Level "警告" -Message "Windows 病毒防护的实时保护没有开启"
    }
    if ($defender.AntivirusSignatureLastUpdated) {
        $sigDays = ($now - $defender.AntivirusSignatureLastUpdated).Days
        if ($sigDays -ge 7) {
            Add-Finding -Level "注意" -Message ("病毒库已经 {0} 天没更新" -f $sigDays)
        }
    }
}
else {
    Write-Item "病毒防护" "无法读取状态(可能装了第三方杀毒软件)" "DarkGray"
}

# ---------- 系统状态 ----------
Write-Section "系统状态"

$pendingReboot = $false
foreach ($path in @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending",
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired")) {
    if (Test-Path $path) { $pendingReboot = $true }
}

if ($pendingReboot) {
    Write-Item "待重启" "有未完成的更新,建议重启生效" "Yellow"
    Add-Finding -Level "注意" -Message "系统有待重启的更新"
}
else {
    Write-Item "待重启" "无" "Green"
}

if ($script:ReadIssues.Count -gt 0) {
    Add-Finding -Level "注意" -Message ("以下项目没有读到: " + ($script:ReadIssues -join "、") + "。可以试试用管理员身份重新运行")
}

# ---------- 体检结论 ----------
Write-Section "体检结论"

$warnings = @($script:Findings | Where-Object { $_.Level -eq "警告" })
$notices = @($script:Findings | Where-Object { $_.Level -eq "注意" })

if ($warnings.Count -gt 0) {
    $summary = "发现 {0} 项需要处理的问题" -f $warnings.Count
    $summaryColor = "Yellow"
}
elseif ($notices.Count -gt 0) {
    $summary = "整体正常,有 {0} 项可以优化的地方" -f $notices.Count
    $summaryColor = "Gray"
}
else {
    $summary = "一切正常,电脑状态良好"
    $summaryColor = "Green"
}

Write-Host ("  " + $summary) -ForegroundColor $summaryColor
[void]$script:Report.Add("  " + $summary)

foreach ($finding in $script:Findings) {
    $text = "  [{0}] {1}" -f $finding.Level, $finding.Message
    $color = switch ($finding.Level) {
        "警告" { "Yellow" }
        "正常" { "DarkGray" }
        default { "Gray" }
    }
    Write-Host $text -ForegroundColor $color
    [void]$script:Report.Add($text)
}

$script:Result["findings"] = $script:Findings
$script:Result["summary"] = $summary

# ---------- 保存报告 ----------
if (-not $NoFile) {
    if (-not $OutputPath) {
        $baseDir = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
        $OutputPath = Join-Path $baseDir ("reports\体检报告_{0}.txt" -f $now.ToString("yyyyMMdd_HHmmss"))
    }
    $outDir = Split-Path -Parent $OutputPath
    if ($outDir -and -not (Test-Path $outDir)) {
        New-Item -ItemType Directory -Path $outDir -Force | Out-Null
    }
    $script:Report | Out-File -FilePath $OutputPath -Encoding UTF8
    Write-Host ""
    Write-Host ("  报告已保存: " + $OutputPath) -ForegroundColor DarkCyan

    if ($Json) {
        $jsonPath = [System.IO.Path]::ChangeExtension($OutputPath, ".json")
        $script:Result | ConvertTo-Json -Depth 5 | Out-File -FilePath $jsonPath -Encoding UTF8
        Write-Host ("  JSON 已保存: " + $jsonPath) -ForegroundColor DarkCyan
    }
}

Write-Host ""
