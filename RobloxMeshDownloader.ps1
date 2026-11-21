# ==========================================================
#  Mesh Downloader v2
#  Downloads Roblox meshes / models by ID using Open Cloud.
#  Also listens on localhost so the Studio plugin can send
#  IDs straight to it (no copy-paste needed).
# ==========================================================

$AppVersion = '6.3'
$DefaultUpdateUrl = 'https://raw.githubusercontent.com/BrownPeak64495/roblox-mesh-tools/main'
$Port = 47820

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Net.Http
Add-Type -AssemblyName System.Security
Add-Type -AssemblyName System.Drawing
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# No console window, so show startup errors in a popup instead of failing silently.
trap {
    try { [System.Windows.MessageBox]::Show("Mesh Downloader hit an error:`n`n" + $_.Exception.Message, 'Mesh Downloader') | Out-Null } catch { }
    continue
}

# Only one copy at a time (a second copy couldn't talk to Studio anyway).
$script:mutexCreated = $false
$script:appMutex = New-Object System.Threading.Mutex($true, 'Local\RobloxMeshDownloader', [ref]$script:mutexCreated)
if (-not $script:mutexCreated) {
    $wait = [Diagnostics.Stopwatch]::StartNew()
    $got = $false
    while ($wait.ElapsedMilliseconds -lt 6000) {   # give an updating copy time to close
        try { if ($script:appMutex.WaitOne(500)) { $got = $true; break } } catch [System.Threading.AbandonedMutexException] { $got = $true; break }
    }
    if (-not $got) {
        [System.Windows.MessageBox]::Show('Mesh Downloader is already open - check your taskbar.', 'Mesh Downloader') | Out-Null
        exit
    }
}

# ---------------- storage ----------------
$AppDir       = Join-Path $env:APPDATA 'RobloxMeshDownloader'
$KeyFile      = Join-Path $AppDir 'apikey.dat'
$SettingsFile = Join-Path $AppDir 'settings.json'
# The mesh library lives next to the app (wherever you installed it, e.g. an external drive).
# Only small settings + the encrypted API key stay in AppData.
$LibDir       = Join-Path $PSScriptRoot 'library'       # permanent copy of every .mesh (named <id>.mesh)
$IndexFile    = Join-Path $PSScriptRoot 'library.json'  # names + stats for the Inserter
$TexDir       = Join-Path $LibDir 'textures'   # downloaded texture images (<id>.png / .jpg)
$LookDir      = Join-Path $LibDir 'looks'      # each mesh's look (texture, SurfaceAppearance, colour) as .rbxm
if (-not (Test-Path $AppDir)) { New-Item -ItemType Directory -Path $AppDir | Out-Null }
if (-not (Test-Path $LibDir)) { New-Item -ItemType Directory -Path $LibDir | Out-Null }
# Move a library from older versions (kept in AppData on the C: drive) next to the app.
try {
    $oldLib = Join-Path $AppDir 'library'
    if (Test-Path -LiteralPath $oldLib) {
        foreach ($f in @(Get-ChildItem -LiteralPath $oldLib -File -ErrorAction SilentlyContinue)) {
            $t = Join-Path $LibDir $f.Name
            if (-not (Test-Path -LiteralPath $t)) { Copy-Item -LiteralPath $f.FullName -Destination $t }
        }
        Remove-Item -LiteralPath $oldLib -Recurse -Force
    }
    $oldIndex = Join-Path $AppDir 'library.json'
    if ((Test-Path -LiteralPath $oldIndex) -and -not (Test-Path -LiteralPath $IndexFile)) { Copy-Item -LiteralPath $oldIndex -Destination $IndexFile }
    if (Test-Path -LiteralPath $oldIndex) { Remove-Item -LiteralPath $oldIndex -Force }
} catch { }

function Save-ApiKey([string]$key) {
    if (-not $key) { return }
    $bytes = [Text.Encoding]::UTF8.GetBytes($key)
    $enc = [Security.Cryptography.ProtectedData]::Protect($bytes, $null, [Security.Cryptography.DataProtectionScope]::CurrentUser)
    [IO.File]::WriteAllBytes($KeyFile, $enc)
}

function Load-ApiKey {
    if (Test-Path $KeyFile) {
        try {
            $enc = [IO.File]::ReadAllBytes($KeyFile)
            $bytes = [Security.Cryptography.ProtectedData]::Unprotect($enc, $null, [Security.Cryptography.DataProtectionScope]::CurrentUser)
            return [Text.Encoding]::UTF8.GetString($bytes)
        } catch { return '' }
    }
    return ''
}

function Load-Settings {
    $d = @{
        folder       = (Join-Path $PSScriptRoot 'Roblox Meshes')
        listen       = $true
        openWhenDone = $false
        useFolders   = $true
        installStudio = $true
        centerMesh   = $false
        updateUrl    = $DefaultUpdateUrl
        shortcutFor  = ''
        retries      = 3
        delay        = 2000
    }
    if (Test-Path $SettingsFile) {
        try {
            $j = Get-Content $SettingsFile -Raw | ConvertFrom-Json
            foreach ($p in $j.PSObject.Properties) { $d[$p.Name] = $p.Value }
        } catch { }
    }
    return $d
}

# ---------------- XAML (the window) ----------------
$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Mesh Downloader" Width="1120" Height="720" MinWidth="900" MinHeight="600"
        WindowStyle="None" AllowsTransparency="True" Background="Transparent"
        ResizeMode="CanResizeWithGrip" WindowStartupLocation="CenterScreen"
        FontFamily="Segoe UI" TextOptions.TextFormattingMode="Display" SnapsToDevicePixels="True">
  <Window.Resources>
    <Style x:Key="Card" TargetType="Border">
      <Setter Property="Background" Value="#131316"/>
      <Setter Property="BorderBrush" Value="#24242A"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="CornerRadius" Value="12"/>
      <Setter Property="Padding" Value="18"/>
    </Style>
    <Style x:Key="Field" TargetType="Border">
      <Setter Property="Background" Value="#17171B"/>
      <Setter Property="BorderBrush" Value="#2A2A31"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="CornerRadius" Value="8"/>
      <Setter Property="Padding" Value="12,8"/>
    </Style>
    <Style x:Key="H" TargetType="TextBlock">
      <Setter Property="Foreground" Value="#F2F2F5"/>
      <Setter Property="FontSize" Value="15"/>
      <Setter Property="FontWeight" Value="Bold"/>
    </Style>
    <Style x:Key="FieldLabel" TargetType="TextBlock">
      <Setter Property="Foreground" Value="#8C8C96"/>
      <Setter Property="FontSize" Value="11"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Margin" Value="0,0,0,3"/>
    </Style>
    <Style x:Key="Bare" TargetType="TextBox">
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="Foreground" Value="#EDEDF0"/>
      <Setter Property="CaretBrush" Value="#EDEDF0"/>
      <Setter Property="SelectionBrush" Value="#7C83F5"/>
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="Padding" Value="0"/>
    </Style>
    <Style x:Key="BarePwd" TargetType="PasswordBox">
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="Foreground" Value="#EDEDF0"/>
      <Setter Property="CaretBrush" Value="#EDEDF0"/>
      <Setter Property="SelectionBrush" Value="#7C83F5"/>
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="Padding" Value="0"/>
    </Style>
    <Style x:Key="BtnBase" TargetType="Button">
      <Setter Property="Foreground" Value="#E6E6EA"/>
      <Setter Property="Background" Value="#1C1C21"/>
      <Setter Property="BorderBrush" Value="#2C2C33"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="Height" Value="42"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="Bd" CornerRadius="8" Background="{TemplateBinding Background}"
                    BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="1">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center" Margin="12,0"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Bd" Property="Opacity" Value="0.82"/>
              </Trigger>
              <Trigger Property="IsPressed" Value="True">
                <Setter TargetName="Bd" Property="Opacity" Value="0.65"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter TargetName="Bd" Property="Opacity" Value="0.4"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="BtnPrimary" TargetType="Button" BasedOn="{StaticResource BtnBase}">
      <Setter Property="Background" Value="#7C83F5"/>
      <Setter Property="BorderBrush" Value="#7C83F5"/>
      <Setter Property="Foreground" Value="#FFFFFF"/>
    </Style>
    <Style x:Key="BtnTitle" TargetType="Button" BasedOn="{StaticResource BtnBase}">
      <Setter Property="Width" Value="36"/>
      <Setter Property="Height" Value="32"/>
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="Background" Value="#17171B"/>
    </Style>
    <Style x:Key="Switch" TargetType="CheckBox">
      <Setter Property="Foreground" Value="#E2E2E8"/>
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="CheckBox">
            <Grid Background="Transparent">
              <Grid.ColumnDefinitions>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="Auto"/>
              </Grid.ColumnDefinitions>
              <ContentPresenter VerticalAlignment="Center"/>
              <Border x:Name="Track" Grid.Column="1" Width="38" Height="22" CornerRadius="11" Background="#2A2A31">
                <Ellipse x:Name="Knob" Width="16" Height="16" Margin="3,0" Fill="#8A8A93" HorizontalAlignment="Left"/>
              </Border>
            </Grid>
            <ControlTemplate.Triggers>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="Track" Property="Background" Value="#7C83F5"/>
                <Setter TargetName="Knob" Property="HorizontalAlignment" Value="Right"/>
                <Setter TargetName="Knob" Property="Fill" Value="#FFFFFF"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style TargetType="ScrollBar">
      <Setter Property="Width" Value="8"/>
      <Setter Property="MinWidth" Value="8"/>
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ScrollBar">
            <Track x:Name="PART_Track" IsDirectionReversed="True">
              <Track.Thumb>
                <Thumb>
                  <Thumb.Template>
                    <ControlTemplate TargetType="Thumb">
                      <Border CornerRadius="4" Background="#34343C"/>
                    </ControlTemplate>
                  </Thumb.Template>
                </Thumb>
              </Track.Thumb>
            </Track>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
  </Window.Resources>

  <Border CornerRadius="12" Background="#0C0C0E" BorderBrush="#26262C" BorderThickness="1">
    <Grid>
      <Grid.RowDefinitions>
        <RowDefinition Height="62"/>
        <RowDefinition Height="*"/>
      </Grid.RowDefinitions>

      <!-- Title bar -->
      <Grid x:Name="TitleBar" Background="Transparent" Margin="16,0,14,0">
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="Auto"/>
          <ColumnDefinition Width="*"/>
        </Grid.ColumnDefinitions>
        <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
          <Border Width="36" Height="36" CornerRadius="9" Background="#1A1A22" BorderBrush="#30303A" BorderThickness="1">
            <TextBlock Text="MD" Foreground="#A3A8FF" FontWeight="Bold" FontSize="13"
                       HorizontalAlignment="Center" VerticalAlignment="Center"/>
          </Border>
          <StackPanel Margin="11,0,0,0" VerticalAlignment="Center">
            <TextBlock Text="Mesh Downloader" Foreground="#F2F2F5" FontWeight="Bold" FontSize="15"/>
            <TextBlock x:Name="VersionText" Text="v4.3" Foreground="#6F6F78" FontSize="11"/>
          </StackPanel>
        </StackPanel>
        <Border Grid.Column="1" CornerRadius="8" Background="#141418" BorderBrush="#2A2A31"
                BorderThickness="1" Padding="16,8" VerticalAlignment="Center">
          <StackPanel Orientation="Horizontal">
            <Ellipse x:Name="LinkDot" Width="8" Height="8" Fill="#6F6F78" VerticalAlignment="Center"/>
            <TextBlock x:Name="LinkText" Text="Studio link: starting..." Foreground="#D0D0D8"
                       FontSize="12.5" FontWeight="SemiBold" Margin="9,0,0,0"/>
          </StackPanel>
        </Border>
        <StackPanel Grid.Column="2" Orientation="Horizontal" HorizontalAlignment="Right" VerticalAlignment="Center">
          <Button x:Name="BtnMin" Style="{StaticResource BtnTitle}" Content="&#x2013;"/>
          <Button x:Name="BtnClose" Style="{StaticResource BtnTitle}" Content="&#x2715;" Margin="8,0,0,0"/>
        </StackPanel>
      </Grid>
      <Border Grid.Row="0" Height="1" Background="#1D1D22" VerticalAlignment="Bottom"/>

      <!-- Body -->
      <Grid Grid.Row="1" Margin="16">
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="16"/>
          <ColumnDefinition Width="370"/>
        </Grid.ColumnDefinitions>

        <Grid>
          <Grid.RowDefinitions>
            <RowDefinition Height="*"/>
            <RowDefinition Height="16"/>
            <RowDefinition Height="*"/>
          </Grid.RowDefinitions>

          <!-- Asset IDs -->
          <Border Style="{StaticResource Card}">
            <Grid>
              <Grid.RowDefinitions>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="*"/>
                <RowDefinition Height="Auto"/>
              </Grid.RowDefinitions>
              <DockPanel Margin="0,0,0,12" LastChildFill="False">
                <TextBlock Text="Asset IDs" Style="{StaticResource H}" DockPanel.Dock="Left"/>
                <TextBlock x:Name="QueueCount" Text="Mesh IDs, model IDs, rbxassetid:// links, or plugin lines"
                           Foreground="#7A7A84" FontSize="11.5" DockPanel.Dock="Right" VerticalAlignment="Center"/>
              </DockPanel>
              <Border Grid.Row="1" Style="{StaticResource Field}">
                <Grid>
                  <TextBlock x:Name="IdsPlaceholder" Foreground="#4E4E57" FontFamily="Consolas" FontSize="13" IsHitTestVisible="False"
                             Text="1234567890 | AK47_Magazine | AK47&#10;9876543210&#10;rbxassetid://5555555555&#10;&#10;Tip: use the Studio plugin's Send button to fill this automatically."/>
                  <TextBox x:Name="IdsBox" Style="{StaticResource Bare}" FontFamily="Consolas" AcceptsReturn="True"
                           TextWrapping="NoWrap" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled"/>
                </Grid>
              </Border>
              <Grid Grid.Row="2" Margin="0,12,0,0">
                <Grid.ColumnDefinitions>
                  <ColumnDefinition Width="2*"/>
                  <ColumnDefinition Width="10"/>
                  <ColumnDefinition Width="*"/>
                  <ColumnDefinition Width="10"/>
                  <ColumnDefinition Width="*"/>
                </Grid.ColumnDefinitions>
                <Button x:Name="BtnStart" Style="{StaticResource BtnPrimary}" Content="Start"/>
                <Button x:Name="BtnPause" Grid.Column="2" Style="{StaticResource BtnBase}" Content="Pause" IsEnabled="False"/>
                <Button x:Name="BtnStop" Grid.Column="4" Style="{StaticResource BtnBase}" Content="Stop" IsEnabled="False"/>
              </Grid>
            </Grid>
          </Border>

          <!-- Output -->
          <Border Grid.Row="2" Style="{StaticResource Card}">
            <Grid>
              <Grid.RowDefinitions>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="*"/>
                <RowDefinition Height="Auto"/>
              </Grid.RowDefinitions>
              <DockPanel Margin="0,0,0,12" LastChildFill="False">
                <TextBlock Text="Output" Style="{StaticResource H}" DockPanel.Dock="Left"/>
                <TextBlock x:Name="RunSummary" Text="No run yet" Foreground="#7A7A84" FontSize="11.5"
                           DockPanel.Dock="Right" VerticalAlignment="Center"/>
              </DockPanel>
              <Border Grid.Row="1" Style="{StaticResource Field}">
                <TextBox x:Name="LogBox" Style="{StaticResource Bare}" FontFamily="Consolas" FontSize="12"
                         Foreground="#B9B9C2" IsReadOnly="True" TextWrapping="Wrap"
                         VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled"/>
              </Border>
              <Grid Grid.Row="2" Margin="0,12,0,0">
                <Grid.ColumnDefinitions>
                  <ColumnDefinition Width="*"/>
                  <ColumnDefinition Width="10"/>
                  <ColumnDefinition Width="*"/>
                </Grid.ColumnDefinitions>
                <Button x:Name="BtnOpen" Style="{StaticResource BtnBase}" Content="Open save folder"/>
                <Button x:Name="BtnClearLog" Grid.Column="2" Style="{StaticResource BtnBase}" Content="Clear output"/>
              </Grid>
            </Grid>
          </Border>
        </Grid>

        <!-- Right column -->
        <Border Grid.Column="2" Style="{StaticResource Card}">
          <ScrollViewer VerticalScrollBarVisibility="Auto">
            <StackPanel>
              <TextBlock Text="Quick Setup" Style="{StaticResource H}" Margin="0,0,0,12"/>

              <Border Style="{StaticResource Field}">
                <Grid>
                  <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="Auto"/>
                  </Grid.ColumnDefinitions>
                  <StackPanel VerticalAlignment="Center">
                    <TextBlock Text="Open Cloud API Key" Style="{StaticResource FieldLabel}"/>
                    <PasswordBox x:Name="KeyBox" Style="{StaticResource BarePwd}"/>
                  </StackPanel>
                  <Button x:Name="BtnGetKey" Grid.Column="1" Style="{StaticResource BtnBase}" Content="Get Key"
                          Height="34" Margin="10,0,0,0"/>
                </Grid>
              </Border>

              <Border Style="{StaticResource Field}" Margin="0,10,0,0">
                <Grid>
                  <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="Auto"/>
                  </Grid.ColumnDefinitions>
                  <StackPanel VerticalAlignment="Center">
                    <TextBlock Text="Save Folder" Style="{StaticResource FieldLabel}"/>
                    <TextBox x:Name="FolderBox" Style="{StaticResource Bare}"/>
                  </StackPanel>
                  <Button x:Name="BtnBrowse" Grid.Column="1" Style="{StaticResource BtnBase}" Content="Browse"
                          Height="34" Margin="10,0,0,0"/>
                </Grid>
              </Border>

              <StackPanel Margin="0,18,0,0">
                <CheckBox x:Name="TglListen" Style="{StaticResource Switch}" Content="Listen for Studio plugin"/>
                <CheckBox x:Name="TglFolders" Style="{StaticResource Switch}" Content="Use model folders from plugin" Margin="0,14,0,0"/>
                <CheckBox x:Name="TglOpen" Style="{StaticResource Switch}" Content="Open folder when done" Margin="0,14,0,0"/>
                <CheckBox x:Name="TglCenterMesh" Style="{StaticResource Switch}" Content="Center origin of saved .mesh files" Margin="0,14,0,0"
                          ToolTip="Moves each saved (named) .mesh so its origin is the middle of the mesh. Static meshes only - skinned meshes are left alone so their bones still line up."/>
              </StackPanel>

              <Border Height="1" Background="#222228" Margin="0,20"/>

              <TextBlock Text="Local Models" Style="{StaticResource H}" Margin="0,0,0,12"/>
              <CheckBox x:Name="TglInstall" Style="{StaticResource Switch}" Content="Install meshes into Studio"/>
              <TextBlock x:Name="StudioStatus" Text="Checking Studio..." Foreground="#8C8C96" FontSize="11.5"
                         TextWrapping="Wrap" Margin="0,8,0,10"/>
              <Button x:Name="BtnConvert" Style="{StaticResource BtnPrimary}" Content="Make .rbxmx local..." Height="38"/>
              <TextBlock Text="or drag .rbxmx files here - or save them into the Make Local folder (automatic)" Foreground="#6F6F78" FontSize="11"
                         HorizontalAlignment="Center" Margin="0,6,0,10"/>
              <Button x:Name="BtnSync" Style="{StaticResource BtnBase}" Content="Sync meshes to Studio now" Height="36"/>

              <Border Height="1" Background="#222228" Margin="0,20"/>

              <TextBlock Text="Advanced Settings" Style="{StaticResource H}" Margin="0,0,0,12"/>
              <Grid>
                <Grid.ColumnDefinitions>
                  <ColumnDefinition Width="*"/>
                  <ColumnDefinition Width="10"/>
                  <ColumnDefinition Width="*"/>
                </Grid.ColumnDefinitions>
                <Border Style="{StaticResource Field}">
                  <StackPanel>
                    <TextBlock Text="Download retries" Style="{StaticResource FieldLabel}"/>
                    <TextBox x:Name="RetriesBox" Style="{StaticResource Bare}" FontSize="15"/>
                  </StackPanel>
                </Border>
                <Border Grid.Column="2" Style="{StaticResource Field}">
                  <StackPanel>
                    <TextBlock Text="Retry delay (ms)" Style="{StaticResource FieldLabel}"/>
                    <TextBox x:Name="DelayBox" Style="{StaticResource Bare}" FontSize="15"/>
                  </StackPanel>
                </Border>
              </Grid>

              <Border Style="{StaticResource Field}" Margin="0,10,0,0">
                <StackPanel>
                  <TextBlock Text="Update source (folder URL - see README)" Style="{StaticResource FieldLabel}"/>
                  <TextBox x:Name="UpdateBox" Style="{StaticResource Bare}" FontSize="12"/>
                </StackPanel>
              </Border>
              <Button x:Name="BtnUpdate" Style="{StaticResource BtnBase}" Content="Check for updates" Height="36" Margin="0,10,0,0"/>

              <Border Style="{StaticResource Field}" Margin="0,18,0,0" Background="#15151A">
                <TextBlock TextWrapping="Wrap" Foreground="#8C8C96" FontSize="11.5" LineHeight="17">
                  <Run Text="How it works" FontWeight="Bold" Foreground="#C9C9D1"/>
                  <LineBreak/>
                  <Run Text="Mesh IDs save as .mesh files. Model IDs save as .rbxm (drag into Studio). Failed IDs go back into the Asset IDs box so you can retry. With Install meshes into Studio on, every mesh is also copied into Studio's content folder so the plugin's Build local .rbxm can use it - and re-copied automatically after Studio updates."/>
                </TextBlock>
              </Border>
            </StackPanel>
          </ScrollViewer>
        </Border>
      </Grid>
    </Grid>
  </Border>
</Window>
'@

try {
    $reader = New-Object System.Xml.XmlNodeReader ([xml]$xaml)
    $window = [Windows.Markup.XamlReader]::Load($reader)
} catch {
    [System.Windows.MessageBox]::Show("Mesh Downloader couldn't build its window:`n`n" + $_.Exception.Message, 'Mesh Downloader') | Out-Null
    exit 1
}

$names = 'TitleBar','VersionText','LinkDot','LinkText','BtnMin','BtnClose','QueueCount','IdsPlaceholder','IdsBox',
         'BtnStart','BtnPause','BtnStop','RunSummary','LogBox','BtnOpen','BtnClearLog','KeyBox','BtnGetKey',
         'FolderBox','BtnBrowse','TglListen','TglFolders','TglOpen','RetriesBox','DelayBox',
         'TglInstall','StudioStatus','BtnSync','BtnConvert','TglCenterMesh','UpdateBox','BtnUpdate'
foreach ($n in $names) { Set-Variable -Name $n -Value $window.FindName($n) -Scope Script }

$brushConv = New-Object System.Windows.Media.BrushConverter
function Get-Brush([string]$hex) { return $brushConv.ConvertFromString($hex) }

# ---------------- UI helpers ----------------
$script:DoEventsCallback = [System.Windows.Threading.DispatcherOperationCallback]{ param($f) $f.Continue = $false; return $null }
function Invoke-DoEvents {
    $frame = New-Object System.Windows.Threading.DispatcherFrame
    [void][System.Windows.Threading.Dispatcher]::CurrentDispatcher.BeginInvoke(
        [System.Windows.Threading.DispatcherPriority]::Background, $script:DoEventsCallback, $frame)
    [System.Windows.Threading.Dispatcher]::PushFrame($frame)
}

function Wait-Task($task) {
    while (-not $task.IsCompleted) { Invoke-DoEvents; Start-Sleep -Milliseconds 10 }
}

function Wait-Ms([int]$ms) {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt $ms) { Invoke-DoEvents; Start-Sleep -Milliseconds 15 }
}

function Log([string]$msg) {
    if ($msg) {
        $stamp = (Get-Date).ToString('HH:mm:ss')
        $LogBox.AppendText("[$stamp] $msg`r`n")
    } else {
        $LogBox.AppendText("`r`n")
    }
    $LogBox.ScrollToEnd()
}

function Set-Link([string]$state, [string]$text) {
    switch ($state) {
        'connected' { $LinkDot.Fill = Get-Brush '#3DDC84' }
        'on'        { $LinkDot.Fill = Get-Brush '#F2C14E' }
        'err'       { $LinkDot.Fill = Get-Brush '#F25F5C' }
        default     { $LinkDot.Fill = Get-Brush '#6F6F78' }
    }
    $LinkText.Text = $text
}

function Set-RunningUI([bool]$running) {
    $BtnStart.IsEnabled = -not $running
    $BtnPause.IsEnabled = $running
    $BtnStop.IsEnabled  = $running
    $BtnPause.Content   = 'Pause'
}

# ---------------- parsing ----------------
function Clean-Field([string]$s) {
    if (-not $s) { return '' }
    return ($s -replace '[\|\r\n]', ' ').Trim()
}

function Get-SafeName([string]$n) {
    foreach ($c in [IO.Path]::GetInvalidFileNameChars()) { $n = $n.Replace([string]$c, '_') }
    return $n.Trim().TrimEnd('.')
}

# Line formats accepted:
#   1234567890
#   rbxassetid://1234567890   (or any URL containing the ID)
#   1234567890 | FileName
#   1234567890 | FileName | FolderName
#   1234567890 | FileName | FolderName | noid   (don't add the ID to the file name)
function Get-Entries([string]$text) {
    $list = New-Object System.Collections.Generic.List[object]
    $seen = @{}
    foreach ($line in ($text -split "`r?`n")) {
        if (-not $line.Trim()) { continue }
        $parts  = $line.Split('|')
        $ms     = [regex]::Matches($parts[0], '\d{5,}')
        $name   = $null
        $folder = $null
        $noId   = $false
        if ($ms.Count -eq 1) {
            if ($parts.Count -ge 2) { $name   = $parts[1].Trim() }
            if ($parts.Count -ge 3) { $folder = $parts[2].Trim(); if (-not $folder) { $folder = $null } }
            if ($parts.Count -ge 4) { $noId = ($parts[3].Trim() -eq 'noid') }
        }
        foreach ($m in $ms) {
            $id = $m.Value
            if ($seen.ContainsKey($id)) { continue }
            $seen[$id] = $true
            $raw = $id
            if ($name -or $folder -or $noId) { $raw += " | $name" }
            if ($folder -or $noId) { $raw += " | $folder" }
            if ($noId) { $raw += ' | noid' }
            $list.Add([pscustomobject]@{ Id = $id; Name = $name; Folder = $folder; NoId = $noId; Raw = $raw })
        }
    }
    return ,$list
}

function Add-ToQueue($lines) {
    $arr = @($lines)
    if ($arr.Count -eq 0) { return }
    $t = $IdsBox.Text
    if ($t -and -not $t.EndsWith("`n")) { $t += "`r`n" }
    $IdsBox.Text = $t + ($arr -join "`r`n")
    $IdsBox.ScrollToEnd()
}

# ---------------- file helpers ----------------
function Expand-Gzip([byte[]]$data) {
    $in  = New-Object IO.MemoryStream(,$data)
    $gz  = New-Object IO.Compression.GZipStream($in, [IO.Compression.CompressionMode]::Decompress)
    $out = New-Object IO.MemoryStream
    $gz.CopyTo($out)
    $gz.Dispose(); $in.Dispose()
    return ,$out.ToArray()
}

function Format-Size([long]$n) {
    if ($n -ge 1MB) { return ('{0:N1} MB' -f ($n / 1MB)) }
    return ('{0:N0} KB' -f [Math]::Ceiling($n / 1KB))
}

# Reads the .mesh header: version, size, and whether it has bones.
function Get-MeshInfo([byte[]]$b) {
    $nl = [Array]::IndexOf($b, [byte]10)
    if ($nl -lt 0 -or $nl -gt 32) { return 'mesh (unknown header)' }
    $ver = [Text.Encoding]::ASCII.GetString($b, 0, $nl).Trim()
    $off = $nl + 1
    try {
        if (($ver -like 'version 4.*' -or $ver -like 'version 5.*') -and $b.Length -ge ($off + 24)) {
            $verts = [BitConverter]::ToUInt32($b, $off + 4)
            $faces = [BitConverter]::ToUInt32($b, $off + 8)
            $bones = [BitConverter]::ToUInt16($b, $off + 14)
            $skin  = if ($bones -gt 0) { "SKINNED - $bones bones" } else { 'no bones' }
            return "$ver, $verts verts, $faces tris, $skin"
        }
        if ($ver -like 'version 6.*' -or $ver -like 'version 7.*') {
            $txt = [Text.Encoding]::ASCII.GetString($b)
            $i = $txt.IndexOf('SKINNING')
            if ($i -lt 0) { return "$ver, no bones" }
            $data = $i + 16
            if ($b.Length -ge ($data + 4)) {
                $numSkin = [BitConverter]::ToUInt32($b, $data)
                $bonePos = [long]$data + 4 + ([long]$numSkin * 8)
                if ($bonePos + 4 -le $b.Length) {
                    $bones = [BitConverter]::ToUInt32($b, [int]$bonePos)
                    if ($bones -gt 0 -and $bones -lt 5000) { return "$ver, SKINNED - $bones bones" }
                    if ($bones -eq 0) { return "$ver, no bones" }
                }
            }
            return "$ver, has skinning data"
        }
        if ($ver -like 'version 1.*' -or $ver -like 'version 2.*' -or $ver -like 'version 3.*') {
            return "$ver, static mesh (this format can't hold bones)"
        }
    } catch { }
    return $ver
}

# Size of the mesh's bounding box (used by the plugin to scale SpecialMeshes).
function Get-MeshBounds([byte[]]$b) {
    try {
        $nl = [Array]::IndexOf($b, [byte]10)
        if ($nl -lt 0 -or $nl -gt 32) { return $null }
        $ver = [Text.Encoding]::ASCII.GetString($b, 0, $nl).Trim()
        $off = $nl + 1
        $start = 0; $count = 0; $stride = 0
        if ($ver -like 'version 2.*') {
            $hs = [BitConverter]::ToUInt16($b, $off); $stride = [int]$b[$off + 2]
            $count = [BitConverter]::ToUInt32($b, $off + 4); $start = $off + $hs
        } elseif ($ver -like 'version 3.*') {
            $hs = [BitConverter]::ToUInt16($b, $off); $stride = [int]$b[$off + 2]
            $count = [BitConverter]::ToUInt32($b, $off + 8); $start = $off + $hs
        } elseif ($ver -like 'version 4.*' -or $ver -like 'version 5.*') {
            $hs = [BitConverter]::ToUInt16($b, $off)
            $count = [BitConverter]::ToUInt32($b, $off + 4); $stride = 40; $start = $off + $hs
        } elseif ($ver -like 'version 6.*' -or $ver -like 'version 7.*') {
            $txt = [Text.Encoding]::ASCII.GetString($b)
            $i = $txt.IndexOf('COREMESH')
            if ($i -lt 0) { return $null }
            if ([BitConverter]::ToUInt32($b, $i + 8) -ne 1) { return $null }   # compressed format - can't read
            $data = $i + 16
            $count = [BitConverter]::ToUInt32($b, $data); $stride = 40; $start = $data + 4
        } else { return $null }

        if ($count -le 0 -or $stride -lt 12) { return $null }
        if (([long]$start + [long]$count * $stride) -gt $b.Length) { return $null }

        $minX = [double]::MaxValue; $minY = [double]::MaxValue; $minZ = [double]::MaxValue
        $maxX = [double]::MinValue; $maxY = [double]::MinValue; $maxZ = [double]::MinValue
        $p = $start
        for ($v = 0; $v -lt $count; $v++) {
            $x = [BitConverter]::ToSingle($b, $p); $y = [BitConverter]::ToSingle($b, $p + 4); $z = [BitConverter]::ToSingle($b, $p + 8)
            if ($x -lt $minX) { $minX = $x }; if ($x -gt $maxX) { $maxX = $x }
            if ($y -lt $minY) { $minY = $y }; if ($y -gt $maxY) { $maxY = $y }
            if ($z -lt $minZ) { $minZ = $z }; if ($z -gt $maxZ) { $maxZ = $z }
            $p += $stride
        }
        return ,@([double]($maxX - $minX), [double]($maxY - $minY), [double]($maxZ - $minZ))
    } catch { return $null }
}

# ---------------- Studio content folder (local meshes) ----------------
$script:studioDirs = @()

function Get-StudioContentDirs {
    $roots = @(
        (Join-Path $env:LOCALAPPDATA 'Roblox\Versions'),
        (Join-Path $env:LOCALAPPDATA 'Bloxstrap\Versions'),
        (Join-Path $env:LOCALAPPDATA 'Fishstrap\Versions')
    )
    $dirs = New-Object System.Collections.Generic.List[string]
    foreach ($r in $roots) {
        if (-not (Test-Path $r)) { continue }
        foreach ($v in (Get-ChildItem $r -Directory -ErrorAction SilentlyContinue)) {
            if (Test-Path (Join-Path $v.FullName 'RobloxStudioBeta.exe')) {
                $c = Join-Path $v.FullName 'content'
                if (Test-Path $c) { $dirs.Add($c) }
            }
        }
    }
    return $dirs.ToArray()
}

function Update-StudioStatus {
    $libCount = @(Get-ChildItem $LibDir -Filter '*.mesh' -File -ErrorAction SilentlyContinue).Count
    if (-not $TglInstall.IsChecked) {
        $StudioStatus.Text = "Off. $libCount mesh(es) saved in the library."
    } elseif ($script:studioDirs.Count -eq 0) {
        $StudioStatus.Text = "Roblox Studio wasn't found in AppData. $libCount mesh(es) in the library."
    } else {
        $StudioStatus.Text = "$libCount mesh(es) available to Studio as rbxasset://meshtools/<id>.mesh"
    }
}

# Copies every library mesh into each Studio install that's missing it.
function Sync-Studio([switch]$Quiet) {
    $script:studioDirs = @(Get-StudioContentDirs)
    if ($TglInstall.IsChecked) {
        $lib = @(Get-ChildItem $LibDir -Filter '*.mesh' -File -ErrorAction SilentlyContinue)
        $copied = 0
        foreach ($d in $script:studioDirs) {
            $t = Join-Path $d 'meshtools'
            try { if (-not (Test-Path $t)) { New-Item -ItemType Directory -Path $t -Force | Out-Null } } catch { continue }
            foreach ($f in $lib) {
                $dest = Join-Path $t $f.Name
                if (-not (Test-Path $dest)) {
                    try { Copy-Item -LiteralPath $f.FullName -Destination $dest; $copied++ } catch { }
                }
            }
            # pictures go in content\meshtools\textures (TextureID) and content\textures\meshtools
            # (testing whether SurfaceAppearances accept that one)
            foreach ($tt in @((Join-Path $t 'textures'), (Join-Path $d 'textures\meshtools'))) {
                foreach ($f in @(Get-ChildItem $TexDir -File -ErrorAction SilentlyContinue)) {
                    try {
                        if (-not (Test-Path $tt)) { New-Item -ItemType Directory -Path $tt -Force | Out-Null }
                        $dest = Join-Path $tt $f.Name
                        if (-not (Test-Path $dest)) { Copy-Item -LiteralPath $f.FullName -Destination $dest; $copied++ }
                    } catch { }
                }
            }
        }
        if ($copied -gt 0 -and -not $Quiet) { Log ("Installed {0} mesh file(s) into Studio." -f $copied) }
        if ($copied -gt 0 -and $Quiet) { Log ("Re-installed {0} mesh file(s) into Studio (it may have updated)." -f $copied) }
    }
    Update-StudioStatus
}

# id -> file name of every downloaded texture
function Get-TextureMap {
    $map = @{}
    foreach ($f in @(Get-ChildItem $TexDir -File -ErrorAction SilentlyContinue)) { $map[$f.BaseName] = $f.Name }
    return $map
}

# Paints a picture over a solid colour (what a SurfaceAppearance set to Overlay shows),
# optionally tinted, and saves it as a new solid PNG. TextureID can load that from this PC,
# so dynamic heads keep their skin colour with no Roblox picture ID.
function Bake-Texture([string]$file, [string]$color, [string]$tint) {
    $src = Join-Path $TexDir $file
    if (-not (Test-Path -LiteralPath $src)) { return $null }
    $name = [IO.Path]::GetFileNameWithoutExtension($file) + "_c$color"
    if ($tint -and $tint -ne 'ffffff') { $name += "_t$tint" }
    $name += '.png'
    $dest = Join-Path $TexDir $name
    $script:bakeCreated = $false
    if (-not (Test-Path -LiteralPath $dest)) {
        $script:bakeCreated = $true
        $ms = New-Object IO.MemoryStream (,[IO.File]::ReadAllBytes($src))
        $img = [System.Drawing.Image]::FromStream($ms)
        try {
            $bmp = New-Object System.Drawing.Bitmap $img.Width, $img.Height, ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
            $g = [System.Drawing.Graphics]::FromImage($bmp)
            try {
                $c = [System.Drawing.Color]::FromArgb(255, [Convert]::ToInt32($color.Substring(0, 2), 16), [Convert]::ToInt32($color.Substring(2, 2), 16), [Convert]::ToInt32($color.Substring(4, 2), 16))
                $g.Clear($c)
                $attrs = New-Object System.Drawing.Imaging.ImageAttributes
                if ($tint -and $tint -ne 'ffffff') {
                    $r = [Convert]::ToInt32($tint.Substring(0, 2), 16) / 255.0
                    $gg = [Convert]::ToInt32($tint.Substring(2, 2), 16) / 255.0
                    $b = [Convert]::ToInt32($tint.Substring(4, 2), 16) / 255.0
                    $cm = New-Object System.Drawing.Imaging.ColorMatrix
                    $cm.Matrix00 = [single]$r; $cm.Matrix11 = [single]$gg; $cm.Matrix22 = [single]$b
                    $attrs.SetColorMatrix($cm)
                }
                $rect = New-Object System.Drawing.Rectangle 0, 0, $img.Width, $img.Height
                $g.DrawImage($img, $rect, 0, 0, $img.Width, $img.Height, [System.Drawing.GraphicsUnit]::Pixel, $attrs)
            } finally { $g.Dispose() }
            $bmp.Save($dest, [System.Drawing.Imaging.ImageFormat]::Png)
            $bmp.Dispose()
        } finally { $img.Dispose(); $ms.Dispose() }
    }
    [byte[]]$out = [IO.File]::ReadAllBytes($dest)
    foreach ($d in $script:studioDirs) {
        foreach ($sub in @('meshtools\textures', 'textures\meshtools')) {
            try {
                $t = Join-Path $d $sub
                if (-not (Test-Path $t)) { New-Item -ItemType Directory -Path $t -Force | Out-Null }
                $p = Join-Path $t $name
                if (-not (Test-Path -LiteralPath $p)) { [IO.File]::WriteAllBytes($p, $out); $script:bakeCreated = $true }
            } catch { }
        }
    }
    return $name
}

function Install-Texture([string]$id, [byte[]]$bytes) {
    $ext = '.png'
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xD8) { $ext = '.jpg' }
    elseif ($bytes.Length -ge 4 -and $bytes[0] -eq 0x89 -and $bytes[1] -eq 0x50) { $ext = '.png' }
    else {
        $head = [Text.Encoding]::ASCII.GetString($bytes, 0, [Math]::Min(16, $bytes.Length))
        if ($head.StartsWith('version ') -or $head.StartsWith('<roblox')) { return $null }   # not an image
    }
    if (-not (Test-Path $TexDir)) { New-Item -ItemType Directory -Path $TexDir -Force | Out-Null }
    $name = "$id$ext"
    [IO.File]::WriteAllBytes((Join-Path $TexDir $name), $bytes)
    if ($TglInstall.IsChecked) {
        foreach ($d in $script:studioDirs) {
            foreach ($sub in @('meshtools\textures', 'textures\meshtools')) {
                try {
                    $t = Join-Path $d $sub
                    if (-not (Test-Path $t)) { New-Item -ItemType Directory -Path $t -Force | Out-Null }
                    [IO.File]::WriteAllBytes((Join-Path $t $name), $bytes)
                } catch { }
            }
        }
    }
    return $name
}

function Install-Mesh([string]$id, [byte[]]$bytes) {
    try { [IO.File]::WriteAllBytes((Join-Path $LibDir "$id.mesh"), $bytes) } catch { return }
    if (-not $TglInstall.IsChecked) { return }
    foreach ($d in $script:studioDirs) {
        try {
            $t = Join-Path $d 'meshtools'
            if (-not (Test-Path $t)) { New-Item -ItemType Directory -Path $t -Force | Out-Null }
            [IO.File]::WriteAllBytes((Join-Path $t "$id.mesh"), $bytes)
        } catch { }
    }
}


# ---------------- mesh stats / centering ----------------
# Where the vertex list is inside a .mesh (versions 2-6). $null if unknown.
function Get-VertexRange([byte[]]$b) {
    $nl = [Array]::IndexOf($b, [byte]10)
    if ($nl -lt 0 -or $nl -gt 32) { return $null }
    $ver = [Text.Encoding]::ASCII.GetString($b, 0, $nl).Trim()
    $off = $nl + 1
    $r = @{ start = 0; count = 0; stride = 0 }
    if ($ver -like 'version 2.*') {
        $r.start = $off + [BitConverter]::ToUInt16($b, $off); $r.stride = [int]$b[$off + 2]
        $r.count = [BitConverter]::ToUInt32($b, $off + 4)
    } elseif ($ver -like 'version 3.*') {
        $r.start = $off + [BitConverter]::ToUInt16($b, $off); $r.stride = [int]$b[$off + 2]
        $r.count = [BitConverter]::ToUInt32($b, $off + 8)
    } elseif ($ver -like 'version 4.*' -or $ver -like 'version 5.*') {
        $r.start = $off + [BitConverter]::ToUInt16($b, $off); $r.stride = 40
        $r.count = [BitConverter]::ToUInt32($b, $off + 4)
    } elseif ($ver -like 'version 6.*' -or $ver -like 'version 7.*') {
        $i = ([Text.Encoding]::ASCII.GetString($b)).IndexOf('COREMESH')
        if ($i -lt 0) { return $null }
        if ([BitConverter]::ToUInt32($b, $i + 8) -ne 1) { return $null }
        $r.count = [BitConverter]::ToUInt32($b, $i + 16); $r.stride = 40; $r.start = $i + 20
    } else { return $null }
    if ($r.count -le 0 -or $r.stride -lt 12) { return $null }
    if (([long]$r.start + [long]$r.count * $r.stride) -gt $b.Length) { return $null }
    return $r
}

function Get-MeshStats([byte[]]$b) {
    $st = @{ version = ''; verts = 0; tris = 0; bones = 0; size = $null }
    try {
        $nl = [Array]::IndexOf($b, [byte]10)
        if ($nl -lt 0 -or $nl -gt 32) { return $st }
        $ver = [Text.Encoding]::ASCII.GetString($b, 0, $nl).Trim()
        $st.version = $ver
        $off = $nl + 1
        if ($ver -like 'version 2.*') {
            $st.verts = [BitConverter]::ToUInt32($b, $off + 4); $st.tris = [BitConverter]::ToUInt32($b, $off + 8)
        } elseif ($ver -like 'version 3.*') {
            $st.verts = [BitConverter]::ToUInt32($b, $off + 8); $st.tris = [BitConverter]::ToUInt32($b, $off + 12)
        } elseif ($ver -like 'version 4.*' -or $ver -like 'version 5.*') {
            $st.verts = [BitConverter]::ToUInt32($b, $off + 4); $st.tris = [BitConverter]::ToUInt32($b, $off + 8)
            $st.bones = [BitConverter]::ToUInt16($b, $off + 14)
        } elseif ($ver -like 'version 6.*' -or $ver -like 'version 7.*') {
            $txt = [Text.Encoding]::ASCII.GetString($b)
            $r = Get-VertexRange $b
            if ($r) {
                $st.verts = $r.count
                $fp = $r.start + $r.count * $r.stride
                if ($fp + 4 -le $b.Length) { $st.tris = [BitConverter]::ToUInt32($b, [int]$fp) }
            }
            $i = $txt.IndexOf('SKINNING')
            if ($i -ge 0 -and $b.Length -ge ($i + 20)) {
                $numSkin = [BitConverter]::ToUInt32($b, $i + 16)
                $bp = [long]$i + 20 + ([long]$numSkin * 8)
                if ($bp + 4 -le $b.Length) {
                    $bn = [BitConverter]::ToUInt32($b, [int]$bp)
                    if ($bn -lt 5000) { $st.bones = $bn } else { $st.bones = -1 }
                } else { $st.bones = -1 }
            }
        }
        $st.size = Get-MeshBounds $b
    } catch { }
    return $st
}

# Copy of the mesh with its vertices moved so the middle of the mesh is at 0,0,0.
# Returns $null for skinned meshes (moving them would break the bones) or unknown formats.
function Center-MeshBytes([byte[]]$b) {
    try {
        $st = Get-MeshStats $b
        if ($st.bones -ne 0) { return $null }
        $r = Get-VertexRange $b
        if (-not $r) { return $null }
        $minX = [double]::MaxValue; $minY = [double]::MaxValue; $minZ = [double]::MaxValue
        $maxX = [double]::MinValue; $maxY = [double]::MinValue; $maxZ = [double]::MinValue
        $p = $r.start
        for ($v = 0; $v -lt $r.count; $v++) {
            $x = [BitConverter]::ToSingle($b, $p); $y = [BitConverter]::ToSingle($b, $p + 4); $z = [BitConverter]::ToSingle($b, $p + 8)
            if ($x -lt $minX) { $minX = $x }; if ($x -gt $maxX) { $maxX = $x }
            if ($y -lt $minY) { $minY = $y }; if ($y -gt $maxY) { $maxY = $y }
            if ($z -lt $minZ) { $minZ = $z }; if ($z -gt $maxZ) { $maxZ = $z }
            $p += $r.stride
        }
        $cx = ($minX + $maxX) / 2; $cy = ($minY + $maxY) / 2; $cz = ($minZ + $maxZ) / 2
        if ([Math]::Abs($cx) -lt 1e-5 -and [Math]::Abs($cy) -lt 1e-5 -and [Math]::Abs($cz) -lt 1e-5) { return ,$b }
        [byte[]]$out = $b.Clone()
        $p = $r.start
        for ($v = 0; $v -lt $r.count; $v++) {
            $x = [BitConverter]::ToSingle($b, $p) - $cx
            $y = [BitConverter]::ToSingle($b, $p + 4) - $cy
            $z = [BitConverter]::ToSingle($b, $p + 8) - $cz
            [Array]::Copy([BitConverter]::GetBytes([single]$x), 0, $out, $p, 4)
            [Array]::Copy([BitConverter]::GetBytes([single]$y), 0, $out, $p + 4, 4)
            [Array]::Copy([BitConverter]::GetBytes([single]$z), 0, $out, $p + 8, 4)
            $p += $r.stride
        }
        return ,$out
    } catch { return $null }
}

# ---------------- library index (for the Inserter) ----------------
$script:index = @{}
function Load-Index {
    $script:index = @{}
    if (Test-Path $IndexFile) {
        try {
            $j = Get-Content $IndexFile -Raw | ConvertFrom-Json
            foreach ($p in $j.PSObject.Properties) {
                $h = @{}
                foreach ($q in $p.Value.PSObject.Properties) { $h[$q.Name] = $q.Value }
                $script:index[$p.Name] = $h
            }
        } catch { }
    }
}
function Save-Index {
    try { $script:index | ConvertTo-Json -Depth 6 | Set-Content -Path $IndexFile -Encoding UTF8 } catch { }
}
function New-IndexEntry([string]$name, $rel, [byte[]]$bytes, [string]$date) {
    $st = Get-MeshStats $bytes
    return @{
        name = $name; file = $rel; version = $st.version; verts = $st.verts; tris = $st.tris
        bones = $st.bones; size = $st.size; bytes = $bytes.Length; date = $date
    }
}
function Update-IndexEntry([string]$id, [string]$name, [string]$rel, [byte[]]$bytes) {
    $script:index[$id] = New-IndexEntry $name $rel $bytes ((Get-Date).ToString('yyyy-MM-dd HH:mm'))
    Save-Index
}

function Get-SaveRoot {
    $r = $FolderBox.Text.Trim()
    if (-not $r) { return $null }
    try {
        if (-not (Test-Path $r)) { New-Item -ItemType Directory -Path $r -Force | Out-Null }
        return (Resolve-Path $r).ProviderPath.TrimEnd('\')
    } catch { return $null }
}

# Turns a relative key from the plugin into a full path, only inside the save folder.
function Resolve-SafeModelPath([string]$key) {
    if (-not $key) { return $null }
    $root = Get-SaveRoot
    if (-not $root) { return $null }
    try { $full = [IO.Path]::GetFullPath((Join-Path $root $key)) } catch { return $null }
    if (-not $full.StartsWith($root + '\', [StringComparison]::OrdinalIgnoreCase)) { return $null }
    if (-not (Test-Path -LiteralPath $full)) { return $null }
    return $full
}

function Get-LibraryData {
    $meshes = New-Object System.Collections.Generic.List[object]
    $changed = $false
    foreach ($f in @(Get-ChildItem $LibDir -Filter '*.mesh' -File -ErrorAction SilentlyContinue)) {
        $id = $f.BaseName
        if (-not $script:index.ContainsKey($id)) {
            try {
                $script:index[$id] = New-IndexEntry $id $null ([IO.File]::ReadAllBytes($f.FullName)) ($f.LastWriteTime.ToString('yyyy-MM-dd HH:mm'))
                $changed = $true
            } catch { continue }
        }
        $e = $script:index[$id]
        $meshes.Add(@{
            id = $id; name = [string]$e.name; file = $e.file; version = $e.version; verts = $e.verts; tris = $e.tris
            bones = $e.bones; size = $e.size; bytes = $e.bytes; date = $e.date; source = [string]$e.source
            look = (Test-Path -LiteralPath (Join-Path $LookDir "$id.rbxm"))
        })
    }
    if ($changed) { Save-Index }

    $models = New-Object System.Collections.Generic.List[object]
    $root = Get-SaveRoot
    if ($root) {
        $files = @(Get-ChildItem $root -Recurse -File -ErrorAction SilentlyContinue | Where-Object {
            ($_.Extension -eq '.rbxm' -or $_.Extension -eq '.rbxmx') -and $_.FullName -notlike '*\Make Local\*' })
        foreach ($f in $files) {
            $rel = $f.FullName.Substring($root.Length).TrimStart('\')
            $models.Add(@{
                key = $rel; name = $f.BaseName; folder = [IO.Path]::GetDirectoryName($rel); ext = $f.Extension
                bytes = $f.Length; date = $f.LastWriteTime.ToString('yyyy-MM-dd HH:mm')
            })
        }
    }
    return @{ ok = $true; meshes = [object[]]$meshes.ToArray(); models = [object[]]$models.ToArray(); textures = (Get-TextureMap) }
}


# ---------------- plugin install + self-update ----------------
# Copies MeshCollector.lua (next to this script) into Studio's Plugins folder
# whenever it changed, and moves model files out of the Plugins folder.
function Install-Plugin {
    try {
        $src = Join-Path $PSScriptRoot 'MeshCollector.lua'
        if (-not (Test-Path -LiteralPath $src)) { return }
        $dir = Join-Path $env:LOCALAPPDATA 'Roblox\Plugins'
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        $dest = Join-Path $dir 'MeshCollector.lua'
        [byte[]]$new = [IO.File]::ReadAllBytes($src)
        $same = $false
        if (Test-Path -LiteralPath $dest) {
            [byte[]]$old = [IO.File]::ReadAllBytes($dest)
            $same = ($old.Length -eq $new.Length) -and ([Convert]::ToBase64String($old) -eq [Convert]::ToBase64String($new))
        }
        if (-not $same) {
            [IO.File]::WriteAllBytes($dest, $new)
            Log 'Studio plugin installed/updated. Restart Studio to load the new version.'
        }
        if (Test-Path -LiteralPath (Join-Path $dir 'MeshIdCollector.lua')) {
            Log 'Tip: delete the old MeshIdCollector.lua from your Plugins folder (v1 leftover).'
        }
        $stray = @(Get-ChildItem $dir -File -ErrorAction SilentlyContinue | Where-Object {
            ($_.Extension -eq '.rbxm' -or $_.Extension -eq '.rbxmx') -and $_.Name -like '*`[local`]*' })
        $root = Get-SaveRoot
        if ($stray.Count -gt 0 -and $root) {
            $dst = Join-Path $root 'Local Models'
            if (-not (Test-Path $dst)) { New-Item -ItemType Directory -Path $dst -Force | Out-Null }
            foreach ($f in $stray) {
                $target = Join-Path $dst $f.Name
                $n = 2
                while (Test-Path -LiteralPath $target) { $target = Join-Path $dst ("{0} ({1}){2}" -f $f.BaseName, $n, $f.Extension); $n++ }
                try { Move-Item -LiteralPath $f.FullName -Destination $target } catch { }
            }
            Log ("Moved {0} saved model(s) out of Studio's Plugins folder into Local Models." -f $stray.Count)
        }
    } catch {
        Log ("Couldn't install the Studio plugin automatically: {0}" -f $_.Exception.Message)
    }
}

# Desktop + Start menu shortcuts (made once per install folder; if you delete
# them they stay deleted until the folder moves).
function Install-Shortcuts {
    try {
        $app = $PSCommandPath
        if ($script:shortcutFor -eq $app) { return }
        $ico = Join-Path $PSScriptRoot 'MeshDownloader.ico'
        $shell = New-Object -ComObject WScript.Shell
        $made = 0
        foreach ($dir in @([Environment]::GetFolderPath('Desktop'), [Environment]::GetFolderPath('Programs'))) {
            if (-not $dir -or -not (Test-Path -LiteralPath $dir)) { continue }
            $lnk = $shell.CreateShortcut((Join-Path $dir 'Mesh Downloader.lnk'))
            $lnk.TargetPath = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
            $lnk.Arguments = '-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "' + $app + '"'
            $lnk.WorkingDirectory = $PSScriptRoot
            $lnk.WindowStyle = 7   # start minimized so no console flashes up
            if (Test-Path -LiteralPath $ico) { $lnk.IconLocation = "$ico,0" }
            $lnk.Description = 'Mesh Downloader - Roblox mesh tools'
            $lnk.Save()
            $made++
        }
        $script:shortcutFor = $app
        Save-Settings
        if ($made -gt 0) { Log 'Added a Mesh Downloader icon to your Desktop and Start menu.' }
    } catch {
        Log ("Couldn't make the Desktop icon: {0}" -f $_.Exception.Message)
    }
}

function Set-WindowIcon {
    try {
        $ico = Join-Path $PSScriptRoot 'MeshDownloader.ico'
        if (Test-Path -LiteralPath $ico) {
            # Read it into memory first - opening it by path keeps the file locked,
            # which stopped the updater from replacing it.
            $ms = New-Object System.IO.MemoryStream(,[IO.File]::ReadAllBytes($ico))
            $window.Icon = [System.Windows.Media.Imaging.BitmapFrame]::Create($ms, [System.Windows.Media.Imaging.BitmapCreateOptions]::None, [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad)
        }
    } catch { }
}

# Update source = a web folder holding version.json + the tool files.
# version.json: { "version": "3.1", "files": ["RobloxMeshDownloader.ps1", "MeshCollector.lua", ...] }
function Check-Updates([switch]$Manual) {
    $url = $UpdateBox.Text.Trim().TrimEnd('/')
    if (-not $url) {
        if ($Manual) { Log 'No update source set yet - see README (Automatic updates).' }
        return
    }
    if ($url -notmatch '^https://') { Log 'The update source has to start with https://'; return }
    if ($script:busy) { if ($Manual) { Log 'Finish the current downloads first.' }; return }
    try {
        $stamp = [DateTime]::UtcNow.Ticks
        $t = $client.GetStringAsync("$url/version.json?t=$stamp"); Wait-Task $t
        $info = $t.GetAwaiter().GetResult() | ConvertFrom-Json
        $remote = [version]([string]$info.version)
        if ($remote -le [version]$AppVersion) {
            if ($Manual) { Log "You're on the newest version (v$AppVersion)." }
            return
        }
        Log "Updating to v$remote..."
        $tmp = Join-Path $PSScriptRoot '_update'
        if (Test-Path $tmp) { Remove-Item -LiteralPath $tmp -Recurse -Force }
        New-Item -ItemType Directory -Path $tmp | Out-Null
        $names = @()
        foreach ($f in @($info.files)) {
            $name = [IO.Path]::GetFileName([string]$f)
            if (-not $name) { continue }
            $t2 = $client.GetByteArrayAsync("$url/" + [Uri]::EscapeDataString($name) + "?t=$stamp"); Wait-Task $t2
            [byte[]]$bytes = $t2.GetAwaiter().GetResult()
            if ($bytes.Length -eq 0) { throw "downloaded file was empty: $name" }
            [IO.File]::WriteAllBytes((Join-Path $tmp $name), $bytes)
            $names += $name
        }
        if ($names.Count -eq 0) { throw 'version.json lists no files' }
        $busy = @()
        foreach ($name in $names) {
            $from = Join-Path $tmp $name
            $to = Join-Path $PSScriptRoot $name
            if (Test-Path -LiteralPath $to) {
                $a = [IO.File]::ReadAllBytes($from); $b = [IO.File]::ReadAllBytes($to)
                if ($a.Length -eq $b.Length -and [Convert]::ToBase64String($a) -eq [Convert]::ToBase64String($b)) { continue }
            }
            try { Copy-Item -LiteralPath $from -Destination $to -Force }
            catch { $busy += $name }
        }
        if ($busy.Count -gt 0) { Log ("Skipped {0} (in use) - it'll update next time." -f ($busy -join ', ')) }
        Install-Plugin
        Save-Settings
        Log "Updated to v$remote. Restarting..."
        $cmd = "Start-Sleep -Seconds 2; & '" + $PSCommandPath.Replace("'", "''") + "'"
        Start-Process powershell -WindowStyle Hidden -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA', '-WindowStyle', 'Hidden', '-Command', $cmd
        $window.Close()
    } catch {
        $ex = $_.Exception
        while ($ex.InnerException) { $ex = $ex.InnerException }
        Log ("Update check failed: {0}" -f $ex.Message)
    }
}

# ---------------- .rbxmx -> local model ----------------
# Rewrites every MeshId in a Roblox XML model to rbxasset://meshtools/<id>.mesh
# so Studio loads the MeshParts from your PC (real MeshParts - bones still work).
$script:MeshPropRx = New-Object System.Text.RegularExpressions.Regex('(<(\w+)\s+name="(?:MeshId|MeshContent)"[^>]*>)(.*?)(</\2>)', [System.Text.RegularExpressions.RegexOptions]::Singleline)
$script:AssetUrlRx = New-Object System.Text.RegularExpressions.Regex('(?:rbxassetid://|https?://(?:www\.)?roblox\.com/asset/?\?id=|https?://assetdelivery\.roblox\.com/v1/asset/?\?id=)(\d{5,})', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)

$script:UrlEvaluator = [System.Text.RegularExpressions.MatchEvaluator]{
    param($u)
    $id = $u.Groups[1].Value
    if (Test-Path (Join-Path $LibDir "$id.mesh")) {
        $script:convHit++
        return "rbxasset://meshtools/$id.mesh"
    }
    [void]$script:convMissing.Add($id)
    return $u.Value
}
$script:PropEvaluator = [System.Text.RegularExpressions.MatchEvaluator]{
    param($m)
    $inner = $script:AssetUrlRx.Replace($m.Groups[3].Value, $script:UrlEvaluator)
    return $m.Groups[1].Value + $inner + $m.Groups[4].Value
}

function Convert-Rbxmx([string]$path, [string]$outDir = '') {
    $file = [IO.Path]::GetFileName($path)
    if ($path -match '\.rbxm$') {
        Log "$file is a binary .rbxm. In Studio use the plugin's Save model button (or right-click > Save to File) and pick the .rbxmx type, then convert that file."
        return $null
    }
    if ($path -notmatch '\.rbxmx$') { Log "$file isn't an .rbxmx model file - skipped."; return $null }
    if (-not $TglInstall.IsChecked) { Log 'Turn on "Install meshes into Studio" first, so Studio has the mesh files.' }

    try { $text = [IO.File]::ReadAllText($path) } catch { Log "Couldn't read $file : $($_.Exception.Message)"; return $null }
    if ($text -notmatch '<roblox') { Log "$file doesn't look like a Roblox XML model - skipped."; return $null }

    $script:convHit = 0
    $script:convMissing = New-Object 'System.Collections.Generic.HashSet[string]'
    $newText = $script:MeshPropRx.Replace($text, $script:PropEvaluator)

    if ($script:convHit -eq 0 -and $script:convMissing.Count -eq 0) {
        Log "$file has no Roblox mesh IDs to replace (already local, or no meshes)."
        return $null
    }

    $dir  = [IO.Path]::GetDirectoryName($path)
    if ($outDir) { $dir = $outDir; if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null } }
    $base = [IO.Path]::GetFileNameWithoutExtension($path)
    if ($base -notlike '* `[local`]') { $base = "$base [local]" }
    $out = Join-Path $dir ($base + '.rbxmx')
    try {
        [IO.File]::WriteAllText($out, $newText, (New-Object System.Text.UTF8Encoding($false)))
    } catch { Log "Couldn't write $out : $($_.Exception.Message)"; return $null }

    Sync-Studio -Quiet
    Log ("{0}: {1} mesh reference(s) now local -> {2}" -f $file, $script:convHit, [IO.Path]::GetFileName($out))
    if ($script:convMissing.Count -gt 0) {
        $ids = @($script:convMissing)
        Add-ToQueue $ids
        Log ("{0} mesh(es) in it aren't downloaded yet - added to Asset IDs. Press Start, then drop the original file in again (it's kept in Make Local\_originals)." -f $ids.Count)
    }
    Log 'Drag the [local] file into Studio to open it.'
    return $out
}

# ---------------- "Make Local" inbox (automatic conversion) ----------------
function Get-InboxDir { return (Join-Path $FolderBox.Text.Trim() 'Make Local') }
function Get-LocalOutDir { return (Join-Path $FolderBox.Text.Trim() 'Local Models') }

function Watch-Inbox {
    $root = $FolderBox.Text.Trim()
    if (-not $root) { return }
    $inbox = Get-InboxDir
    try { if (-not (Test-Path $inbox)) { New-Item -ItemType Directory -Path $inbox -Force | Out-Null } } catch { return }
    $files = @(Get-ChildItem $inbox -File -ErrorAction SilentlyContinue | Where-Object { $_.Extension -in '.rbxmx', '.rbxm' })
    foreach ($f in $files) {
        # wait until Studio has finished writing it
        if (((Get-Date) - $f.LastWriteTime).TotalSeconds -lt 1.5) { continue }
        $done = Join-Path $inbox '_originals'
        if (-not (Test-Path $done)) { New-Item -ItemType Directory -Path $done -Force | Out-Null }
        Log ("Make Local: found {0}" -f $f.Name)
        $out = $null
        if ($f.Extension -eq '.rbxmx') { $out = Convert-Rbxmx $f.FullName (Get-LocalOutDir) }
        else { Log 'That was saved as .rbxm - save it again and pick the .rbxmx type in the save window.' }
        try { Move-Item -LiteralPath $f.FullName -Destination (Join-Path $done $f.Name) -Force } catch { }
        if ($out -and (Test-Path $out)) { Start-Process explorer.exe "/select,`"$out`"" }
    }
}

# ---------------- networking ----------------
$handler = New-Object System.Net.Http.HttpClientHandler
$handler.AutomaticDecompression = [System.Net.DecompressionMethods]::GZip -bor [System.Net.DecompressionMethods]::Deflate
$client = New-Object System.Net.Http.HttpClient($handler)
$client.Timeout = [TimeSpan]::FromSeconds(90)

function Get-StatusHint([int]$code) {
    switch ($code) {
        400 { return 'bad request - check the ID.' }
        401 { return 'not authorized - check the API key, its legacy-asset:manage permission, and its allowed IPs.' }
        403 { return 'access denied - the asset is private, paid, or was taken down.' }
        404 { return 'not found - wrong ID, or it was deleted.' }
        429 { return 'rate limited by Roblox.' }
        default { return "HTTP error $code" }
    }
}

function Get-AssetBytes([string]$id, [string]$key, [int]$retries, [int]$delay) {
    $err = 'unknown error'
    for ($attempt = 0; $attempt -le $retries; $attempt++) {
        if ($attempt -gt 0) {
            Log ("[{0}] retry {1}/{2} in {3} ms ({4})" -f $id, $attempt, $retries, $delay, $err)
            Wait-Ms $delay
            if ($script:stop) { break }
        }
        try {
            $req = New-Object System.Net.Http.HttpRequestMessage([System.Net.Http.HttpMethod]::Get,
                "https://apis.roblox.com/asset-delivery-api/v1/assetId/$id")
            $req.Headers.Add('x-api-key', $key)
            $t1 = $client.SendAsync($req); Wait-Task $t1
            $resp = $t1.GetAwaiter().GetResult()
            $code = [int]$resp.StatusCode
            $t2 = $resp.Content.ReadAsStringAsync(); Wait-Task $t2
            $body = $t2.GetAwaiter().GetResult()

            if (-not $resp.IsSuccessStatusCode) {
                $err = Get-StatusHint $code
                if ($code -eq 429 -or $code -ge 500) { continue }
                break
            }

            $json = $body | ConvertFrom-Json
            $loc = $json.location
            if (-not $loc -and $json.locations) { $loc = @($json.locations)[0].location }
            if (-not $loc) { $err = "Roblox sent no download link: $body"; break }

            $t3 = $client.GetAsync($loc); Wait-Task $t3
            $resp2 = $t3.GetAwaiter().GetResult()
            if (-not $resp2.IsSuccessStatusCode) { $err = "file download failed (HTTP $([int]$resp2.StatusCode))"; continue }
            $t4 = $resp2.Content.ReadAsByteArrayAsync(); Wait-Task $t4
            [byte[]]$bytes = $t4.GetAwaiter().GetResult()
            if ($bytes.Length -ge 2 -and $bytes[0] -eq 0x1F -and $bytes[1] -eq 0x8B) { $bytes = Expand-Gzip $bytes }

            return [pscustomobject]@{ Ok = $true; Bytes = $bytes; Error = $null }
        } catch {
            $ex = $_.Exception
            while ($ex.InnerException) { $ex = $ex.InnerException }
            $err = $ex.Message
            continue
        }
    }
    return [pscustomobject]@{ Ok = $false; Bytes = $null; Error = $err }
}

function Save-Asset($e, [byte[]]$bytes, [string]$root) {
    $head = [Text.Encoding]::ASCII.GetString($bytes, 0, [Math]::Min(16, $bytes.Length))
    $ext = '.bin'; $info = 'unknown file type'
    if ($head.StartsWith('version ')) { $ext = '.mesh'; $info = Get-MeshInfo $bytes }
    elseif ($head.StartsWith('<roblox!')) { $ext = '.rbxm';  $info = 'MODEL file - drag it into Studio to open' }
    elseif ($head.StartsWith('<roblox'))  { $ext = '.rbxmx'; $info = 'MODEL file (XML) - drag it into Studio to open' }
    elseif ($bytes.Length -ge 4 -and $bytes[0] -eq 0x89 -and $head.Substring(1, 3) -eq 'PNG') { $ext = '.png'; $info = 'image/texture, not a mesh' }
    elseif ($bytes.Length -ge 3 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xD8) { $ext = '.jpg'; $info = 'image/texture, not a mesh' }
    elseif ($head.StartsWith('OggS')) { $ext = '.ogg'; $info = 'audio, not a mesh' }
    elseif ($head.StartsWith('ID3'))  { $ext = '.mp3'; $info = 'audio, not a mesh' }

    $dir = $root
    if ($ext -eq '.rbxm' -or $ext -eq '.rbxmx') { $dir = Join-Path $root 'Models' }
    if ($e.Folder -and $TglFolders.IsChecked) {
        $f = Get-SafeName $e.Folder
        if ($f) { $dir = Join-Path $dir $f }
    }
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }

    $base = $e.Id
    if ($e.Name) {
        $n = Get-SafeName $e.Name
        if ($n) {
            if ($e.NoId) { $base = $n } else { $base = '{0}_{1}' -f $n, $e.Id }
        }
    }
    # Two different meshes with the same name in one run -> "Name (2)"
    $k = (Join-Path $dir ($base + $ext)).ToLowerInvariant()
    if ($script:runNames.ContainsKey($k) -and $script:runNames[$k] -ne $e.Id) {
        $i = 2
        while ($script:runNames.ContainsKey((Join-Path $dir ("$base ($i)" + $ext)).ToLowerInvariant())) { $i++ }
        $base = "$base ($i)"
        $k = (Join-Path $dir ($base + $ext)).ToLowerInvariant()
    }
    $script:runNames[$k] = $e.Id

    $outBytes = $bytes
    if ($ext -eq '.mesh' -and $TglCenterMesh.IsChecked) {
        $centered = Center-MeshBytes $bytes
        if ($centered) { $outBytes = $centered; $info += ' (origin centered)' }
        else { $info += ' (origin left as-is: skinned or unsupported version)' }
    }

    $path = Join-Path $dir ($base + $ext)
    try {
        [IO.File]::WriteAllBytes($path, $outBytes)
    } catch {
        Log ("[{0}] FAILED to save file: {1}" -f $e.Id, $_.Exception.Message)
        return $false
    }
    $rel = $path.Substring($root.Length).TrimStart('\')
    if ($ext -eq '.mesh') {
        Install-Mesh $e.Id $bytes      # library + Studio always get the ORIGINAL mesh
        Update-IndexEntry $e.Id $base $rel $bytes
    }
    Log ("[{0}] Saved {1}  ({2})  {3}" -f $e.Id, $rel, (Format-Size $bytes.Length), $info)
    return $true
}

function Get-IntSetting([string]$text, [int]$default, [int]$min, [int]$max) {
    $v = 0
    if ([int]::TryParse($text.Trim(), [ref]$v)) { return [Math]::Max($min, [Math]::Min($max, $v)) }
    return $default
}

function Save-Settings {
    $s = @{
        folder       = $FolderBox.Text.Trim()
        listen       = [bool]$TglListen.IsChecked
        openWhenDone = [bool]$TglOpen.IsChecked
        useFolders   = [bool]$TglFolders.IsChecked
        installStudio = [bool]$TglInstall.IsChecked
        centerMesh   = [bool]$TglCenterMesh.IsChecked
        updateUrl    = $UpdateBox.Text.Trim()
        shortcutFor  = [string]$script:shortcutFor
        retries      = Get-IntSetting $RetriesBox.Text 3 0 10
        delay        = Get-IntSetting $DelayBox.Text 2000 0 60000
    }
    try { $s | ConvertTo-Json | Set-Content -Path $SettingsFile -Encoding UTF8 } catch { }
}

# ---------------- the download run ----------------
$script:busy = $false
$script:paused = $false
$script:stop = $false
$script:closeAfter = $false
$script:autoStartPending = $false
$script:texQueue = New-Object 'System.Collections.Generic.HashSet[string]'

function Start-Batch {
    $key = $KeyBox.Password.Trim()
    if (-not $key) { Log 'Paste your Open Cloud API key on the right first (Get Key opens the page).'; return }
    $root = $FolderBox.Text.Trim()
    if (-not $root) { Log 'Choose a save folder on the right first.'; return }
    try {
        if (-not (Test-Path $root)) { New-Item -ItemType Directory -Path $root -Force | Out-Null }
    } catch { Log "Can't create the save folder: $root"; return }
    $root = (Resolve-Path $root).ProviderPath

    $entries = Get-Entries $IdsBox.Text
    if ($entries.Count -eq 0 -and $script:texQueue.Count -eq 0) { Log 'Nothing to download - paste some IDs (5+ digits) first.'; return }

    Save-ApiKey $key
    Save-Settings
    $IdsBox.Text = ''

    $retries = Get-IntSetting $RetriesBox.Text 3 0 10
    $delay   = Get-IntSetting $DelayBox.Text 2000 0 60000

    $script:busy = $true; $script:stop = $false; $script:paused = $false
    $script:runNames = @{}
    Set-RunningUI $true

    $ok = 0; $fail = 0; $skipped = 0
    $putBack = New-Object System.Collections.Generic.List[string]
    $total = $entries.Count
    Log ("--- Starting {0} download(s) ---" -f $total)

    $i = 0
    foreach ($e in $entries) {
        $i++
        while ($script:paused -and -not $script:stop) { Wait-Ms 100 }
        if ($script:stop) { $putBack.Add($e.Raw); $skipped++; continue }

        $RunSummary.Text = "Downloading $i of $total..."
        $r = Get-AssetBytes $e.Id $key $retries $delay
        if (-not $r.Ok) {
            Log ("[{0}] FAILED: {1}" -f $e.Id, $r.Error)
            $fail++; $putBack.Add($e.Raw); continue
        }
        if (Save-Asset $e $r.Bytes $root) { $ok++ } else { $fail++; $putBack.Add($e.Raw) }
        Wait-Ms 150
    }

    # textures the plugin asked for (TextureID / SurfaceAppearance images)
    $texIds = @($script:texQueue)
    $script:texQueue.Clear()
    $texOk = 0; $texHave = 0
    $texMap = Get-TextureMap
    foreach ($tid in $texIds) {
        if ($script:stop) { break }
        if ($texMap.ContainsKey($tid)) { $texHave++; continue }
        $RunSummary.Text = "Downloading textures..."
        $r = Get-AssetBytes $tid $key $retries $delay
        if ($r.Ok) {
            if (Install-Texture $tid $r.Bytes) { $texOk++ }
        } else {
            Log ("[texture {0}] FAILED: {1}" -f $tid, $r.Error)
        }
        Wait-Ms 120
    }
    if ($texIds.Count -gt 0) { Log ("Textures: {0} downloaded, {1} already saved." -f $texOk, $texHave) }

    if ($putBack.Count -gt 0) {
        Add-ToQueue $putBack
        Log ("{0} ID(s) put back in the Asset IDs box so you can retry." -f $putBack.Count)
    }
    $summary = "$ok saved, $fail failed"
    if ($skipped -gt 0) { $summary += ", $skipped stopped" }
    Log ("--- Done: {0} ---" -f $summary)
    Log ''
    $RunSummary.Text = $summary

    $script:busy = $false
    Set-RunningUI $false
    if ($TglOpen.IsChecked -and $ok -gt 0) { Start-Process explorer.exe $root }
}

function Run-Queue {
    if ($script:busy) { return }
    do {
        $script:autoStartPending = $false
        Start-Batch
    } while ($script:autoStartPending -and -not $script:stop -and -not $script:closeAfter)
    if ($script:closeAfter) { $window.Close() }
}

# ---------------- Studio link (localhost server) ----------------
$script:listener = $null
$script:ctxTask = $null
$script:lastPing = [DateTime]::MinValue
$script:boundsCache = @{}
$script:bonesCache = @{}    # mesh id -> bone count (skinned meshes like dynamic heads)
$script:runNames = @{}
$script:uploads = @{}

# ---------------- Blender (Send to Studio add-on) ----------------
$script:blenderEvents = New-Object System.Collections.Generic.List[object]
$script:toBlender = New-Object System.Collections.Generic.List[object]       # Studio -> Blender, ready
$script:toBlenderWait = New-Object System.Collections.Generic.List[object]   # waiting for a download
$script:blenderTex = @{}        # texture hash -> file name in library\textures
$script:blenderHist = @{}       # object key -> mesh ids sent this session (newest last)
$script:blenderLog = @{}        # object key -> last time we logged it
$script:blenderSeq = 0

# New numeric id for every send, so Studio never shows an old cached copy.
function New-BlenderId([string]$prefix) {
    $script:blenderSeq = ($script:blenderSeq + 1) % 100
    return $prefix + (Get-Date).ToString('yyMMddHHmmss') + $script:blenderSeq.ToString('00')
}
function Read-BodyBytes($ctx) {
    $ms = New-Object IO.MemoryStream
    $ctx.Request.InputStream.CopyTo($ms)
    return ,$ms.ToArray()
}
# Blender add-on body: [4-byte length][JSON][raw bytes]
function Read-Framed($ctx) {
    [byte[]]$all = Read-BodyBytes $ctx
    if ($all.Length -lt 4) { throw 'empty request' }
    $n = [BitConverter]::ToInt32($all, 0)
    if ($n -lt 2 -or $n -gt ($all.Length - 4)) { throw 'bad request' }
    $meta = [Text.Encoding]::UTF8.GetString($all, 4, $n) | ConvertFrom-Json
    $rest = $all.Length - 4 - $n
    [byte[]]$payload = New-Object byte[] $rest
    if ($rest -gt 0) { [Array]::Copy($all, 4 + $n, $payload, 0, $rest) }
    return @{ meta = $meta; bytes = $payload }
}

function Receive-BlenderTexture($ctx) {
    $req = Read-Framed $ctx
    $m = $req.meta
    $hash = [string]$m.hash
    if ($hash -notmatch '^[0-9a-f]{8,40}$') { Send-Json $ctx @{ ok = $false; error = 'bad texture hash' } 400; return }
    [byte[]]$bytes = $req.bytes
    $name = Install-Texture (New-BlenderId '8') $bytes
    if (-not $name) { Send-Json $ctx @{ ok = $false; error = 'texture must be a PNG or JPG' } 400; return }
    $script:blenderTex[$hash] = $name
    Send-Json $ctx @{ ok = $true; file = $name }
}

function Receive-BlenderPose($ctx) {
    $req = Read-Framed $ctx
    $m = $req.meta
    $key = [string]$m.key
    if ($key -notmatch '^[0-9a-f]{6,40}$') { Send-Json $ctx @{ ok = $false; error = 'bad object key' } 400; return }
    for ($i = $script:blenderEvents.Count - 1; $i -ge 0; $i--) {
        $e = $script:blenderEvents[$i]
        if ($e.key -eq $key -and $e.type -eq 'pose') { $script:blenderEvents.RemoveAt($i) }
    }
    $script:blenderEvents.Add(@{ type = 'pose'; key = $key; t = $m.t })
    Send-Json $ctx @{ ok = $true }
}

function Receive-BlenderMesh($ctx) {
    $req = Read-Framed $ctx
    $m = $req.meta
    [byte[]]$bytes = $req.bytes
    $key = [string]$m.key
    if ($key -notmatch '^[0-9a-f]{6,40}$') { Send-Json $ctx @{ ok = $false; error = 'bad object key' } 400; return }
    if (-not $TglInstall.IsChecked) { Send-Json $ctx @{ ok = $false; error = "Turn on 'Install meshes into Studio' in Mesh Downloader" } 409; return }
    if ($script:studioDirs.Count -eq 0) { $script:studioDirs = @(Get-StudioContentDirs) }
    if ($script:studioDirs.Count -eq 0) { Send-Json $ctx @{ ok = $false; error = "Mesh Downloader can't find Roblox Studio" } 409; return }

    # pictures first: the add-on only sends the ones we don't have yet
    $maps = @{}
    $need = New-Object System.Collections.Generic.List[string]
    foreach ($mp in @($m.maps)) {
        if (-not $mp) { continue }
        $h = [string]$mp.hash
        $kind = [string]$mp.kind
        if ($h -notmatch '^[0-9a-f]{8,40}$' -or $kind -notmatch '^(color|normal|roughness|metalness)$') { continue }
        $f = $script:blenderTex[$h]
        if (-not $f -or -not (Test-Path -LiteralPath (Join-Path $TexDir $f))) { $need.Add($h) } else { $maps[$kind] = $f }
    }
    if ($need.Count -gt 0) { Send-Json $ctx @{ ok = $true; needTextures = [object[]]$need.ToArray() }; return }
    $tex = $maps['color']

    $head = ''
    if ($bytes.Length -ge 25) { $head = [Text.Encoding]::ASCII.GetString($bytes, 0, 12) }
    if ($head -ne 'version 2.00' -and $head -ne 'version 7.00') {
        Send-Json $ctx @{ ok = $false; error = 'not a version 2.00 / 7.00 .mesh' } 400; return
    }
    $id = New-BlenderId '9'
    Install-Mesh $id $bytes
    $name = Clean-Field ([string]$m.name)
    if (-not $name) { $name = 'Blender mesh' }

    # keep only the newest copy of this object in the library (and Inserter)
    foreach ($old in @($script:index.Keys)) {
        $e = $script:index[$old]
        if ($old -ne $id -and [string]$e.blender -eq $key) {
            $script:index.Remove($old)
            try { Remove-Item -LiteralPath (Join-Path $LibDir "$old.mesh") -Force -ErrorAction Stop } catch { }
        }
    }
    $entry = New-IndexEntry $name $null $bytes ((Get-Date).ToString('yyyy-MM-dd HH:mm'))
    $entry.source = 'blender'; $entry.blender = $key
    $script:index[$id] = $entry
    Save-Index

    # Studio's copies: keep the last 3 versions of each object (parts may still be showing them)
    if (-not $script:blenderHist.ContainsKey($key)) { $script:blenderHist[$key] = New-Object System.Collections.Generic.List[string] }
    $hist = $script:blenderHist[$key]
    $hist.Add($id)
    while ($hist.Count -gt 3) {
        $gone = $hist[0]; $hist.RemoveAt(0)
        foreach ($d in $script:studioDirs) {
            try { Remove-Item -LiteralPath (Join-Path $d "meshtools\$gone.mesh") -Force -ErrorAction Stop } catch { }
        }
    }

    # tell the plugin (only the newest event per object is kept; a new mesh replaces old poses too)
    for ($i = $script:blenderEvents.Count - 1; $i -ge 0; $i--) {
        if ($script:blenderEvents[$i].key -eq $key) { $script:blenderEvents.RemoveAt($i) }
    }
    $ev = @{
        type = 'mesh'; id = $id; key = $key; name = $name; texture = $tex
        center = @([double]$m.center[0], [double]$m.center[1], [double]$m.center[2])
        size = @([double]$m.size[0], [double]$m.size[1], [double]$m.size[2])
    }
    if ($m.bones) { $ev.bones = @($m.bones) }
    $ev.maps = $maps
    $ev.alpha = [bool]$m.alpha
    $ev.double = [bool]$m.double
    if ($m.tint) { $ev.tint = @([double]$m.tint[0], [double]$m.tint[1], [double]$m.tint[2]) }
    if ([string]$m.look -eq 'overlay' -and $m.color) {
        $ev.look = 'overlay'
        $ev.color = @([double]$m.color[0], [double]$m.color[1], [double]$m.color[2])
    }
    $script:blenderEvents.Add($ev)
    Send-Json $ctx @{ ok = $true; id = $id }

    $now = Get-Date
    $last = $script:blenderLog[$key]
    if (-not $last -or ($now - $last).TotalSeconds -ge 15) {
        $script:blenderLog[$key] = $now
        Log ("Blender: got '{0}' ({1}), waiting for Studio to pick it up." -f $name, (Format-Size $bytes.Length))
    }
}
$script:modelBytesCache = @{ key = $null; bytes = $null }
$script:tickCount = 0

# ---------------- Studio -> Blender ----------------
# A part from Studio, ready once its mesh (and picture) are in the library. $null if still missing.
function Resolve-ToBlender($p, [bool]$noWait = $false) {
    $id = [string]$p.meshId
    if ($id -notmatch '^\d{5,}$') { return $null }
    if (-not (Test-Path -LiteralPath (Join-Path $LibDir "$id.mesh"))) { return $null }
    $tex = ''
    $t = [string]$p.texture
    if ($t -match '^[A-Za-z0-9_.-]+\.(png|jpg)$' -and (Test-Path -LiteralPath (Join-Path $TexDir $t))) { $tex = $t }
    elseif ([string]$p.textureId -match '^\d{5,}$') {
        $tex = (Get-TextureMap)[[string]$p.textureId]
        if (-not $tex) {
            if (-not $noWait) { return $null }
            $tex = ''   # the picture couldn't be downloaded: send the mesh without it
        }
    }
    $ev = @{ key = [string]$p.key; name = (Clean-Field ([string]$p.name)); meshId = $id; texture = $tex
             look = [string]$p.look; transparency = [double]$p.transparency; centerMesh = [bool]$p.centerMesh }
    foreach ($f in @('color', 'cframe', 'size', 'scale')) {
        if ($p.$f) { $ev[$f] = [double[]]@($p.$f) }
    }
    return $ev
}
function Queue-ToBlender($ev) {
    for ($i = $script:toBlender.Count - 1; $i -ge 0; $i--) {
        if ($script:toBlender[$i].key -eq $ev.key) { $script:toBlender.RemoveAt($i) }   # newest only
    }
    $script:toBlender.Add($ev)
}
function Receive-ToBlender($ctx) {
    $sr = New-Object IO.StreamReader($ctx.Request.InputStream, [Text.Encoding]::UTF8)
    $d = $sr.ReadToEnd() | ConvertFrom-Json; $sr.Close()
    $ready = 0; $wait = 0; $bad = 0
    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($p in @($d.parts)) {
        if (-not $p -or [string]$p.key -notmatch '^[0-9a-f]{6,40}$') { $bad++; continue }
        $ev = Resolve-ToBlender $p
        if ($ev) { Queue-ToBlender $ev; $ready++; continue }
        if ([string]$p.meshId -notmatch '^\d{5,}$') { $bad++; continue }
        # not downloaded yet: get it, then pass it on
        for ($i = $script:toBlenderWait.Count - 1; $i -ge 0; $i--) {
            if ($script:toBlenderWait[$i].part.key -eq [string]$p.key) { $script:toBlenderWait.RemoveAt($i) }
        }
        $script:toBlenderWait.Add(@{ part = $p; since = (Get-Date) })
        $wait++
        $mid = [string]$p.meshId
        if (-not (Test-Path -LiteralPath (Join-Path $LibDir "$mid.mesh"))) { $lines.Add($mid) }
        if ([string]$p.textureId -match '^\d{5,}$' -and -not (Get-TextureMap)[[string]$p.textureId]) { [void]$script:texQueue.Add([string]$p.textureId) }
    }
    if ($lines.Count -gt 0) { Add-ToQueue ([string[]]($lines | Select-Object -Unique)) }
    if ($wait -gt 0) { $script:autoStartPending = $true }
    if ($ready + $wait -gt 0 -and -not $d.live) {
        Log ("Studio: sending {0} part(s) to Blender{1}." -f ($ready + $wait), $(if ($wait) { " ($wait downloading first)" } else { '' }))
    }
    Send-Json $ctx @{ ok = $true; ready = $ready; waiting = $wait; skipped = $bad; hasKey = [bool]$KeyBox.Password.Trim() }
}
function Check-ToBlenderWait {
    for ($i = $script:toBlenderWait.Count - 1; $i -ge 0; $i--) {
        $w = $script:toBlenderWait[$i]
        $ev = Resolve-ToBlender $w.part (-not $script:busy -and -not $script:autoStartPending)
        if ($ev) { Queue-ToBlender $ev; $script:toBlenderWait.RemoveAt($i) }
        elseif (((Get-Date) - $w.since).TotalMinutes -gt 10) { $script:toBlenderWait.RemoveAt($i) }
    }
}
function Send-Bytes($ctx, [byte[]]$bytes, [string]$type) {
    try {
        $ctx.Response.StatusCode = 200
        $ctx.Response.ContentType = $type
        $ctx.Response.ContentLength64 = $bytes.Length
        $ctx.Response.OutputStream.Write($bytes, 0, $bytes.Length)
        $ctx.Response.OutputStream.Close()
    } catch { }
}

function Send-Json($ctx, $obj, [int]$code = 200) {
    try {
        $json = $obj | ConvertTo-Json -Compress -Depth 8
        $bytes = [Text.Encoding]::UTF8.GetBytes($json)
        $ctx.Response.StatusCode = $code
        $ctx.Response.ContentType = 'application/json'
        $ctx.Response.ContentLength64 = $bytes.Length
        $ctx.Response.OutputStream.Write($bytes, 0, $bytes.Length)
        $ctx.Response.OutputStream.Close()
    } catch { }
}

# Sends one base64 chunk of a file (big files go in several requests)
function Send-FileChunk($ctx, [string]$full, [int]$chunk) {
    if ($chunk -eq 0 -or $script:modelBytesCache.key -ne $full) {
        $script:modelBytesCache = @{ key = $full; bytes = [IO.File]::ReadAllBytes($full) }
    }
    [byte[]]$fb = $script:modelBytesCache.bytes
    $size = 524286
    $count = [Math]::Max(1, [int][Math]::Ceiling($fb.Length / $size))
    if ($chunk -lt 0 -or $chunk -ge $count) { Send-Json $ctx @{ ok = $false; error = 'bad chunk' } 400; return }
    $start = $chunk * $size
    $len = [Math]::Min($size, $fb.Length - $start)
    Send-Json $ctx @{
        ok = $true; chunk = $chunk; count = $count; ext = [IO.Path]::GetExtension($full)
        data = [Convert]::ToBase64String($fb, $start, $len)
    }
}

function Handle-Request($ctx) {
    try {
        $path = $ctx.Request.Url.AbsolutePath.TrimEnd('/')
        if ($path -eq '/ping') {
            $script:lastPing = Get-Date
            Send-Json $ctx @{ ok = $true; app = 'MeshDownloader'; version = $AppVersion; busy = $script:busy }
            return
        }
        if ($path -eq '/queue' -and $ctx.Request.HttpMethod -eq 'POST') {
            $script:lastPing = Get-Date
            $sr = New-Object IO.StreamReader($ctx.Request.InputStream, [Text.Encoding]::UTF8)
            $body = $sr.ReadToEnd(); $sr.Close()
            $data = $body | ConvertFrom-Json
            $lines = New-Object System.Collections.Generic.List[string]
            foreach ($it in @($data.items)) {
                $id = [string]$it.id
                if ($id -notmatch '^\d{5,}$') { continue }
                $n = Clean-Field ([string]$it.name)
                $f = Clean-Field ([string]$it.folder)
                $noId = [bool]$it.noId
                $line = $id
                if ($n -or $f -or $noId) { $line += " | $n" }
                if ($f -or $noId) { $line += " | $f" }
                if ($noId) { $line += ' | noid' }
                $lines.Add($line)
            }
            $tex = 0
            foreach ($it in @($data.items)) {
                foreach ($tid in @($it.textures)) {
                    $t = [string]$tid
                    if ($t -match '^\d{5,}$' -and $script:texQueue.Add($t)) { $tex++ }
                }
            }
            Add-ToQueue $lines
            Send-Json $ctx @{ ok = $true; queued = $lines.Count; textures = $tex; busy = $script:busy }
            Log ("Received {0} ID(s) and {1} texture(s) from Studio." -f $lines.Count, $tex)
            if ($data.autoStart -and ($lines.Count -gt 0 -or $tex -gt 0)) { $script:autoStartPending = $true }
            return
        }
        if ($path -eq '/status' -and $ctx.Request.HttpMethod -eq 'POST') {
            # Plugin asks which meshes are ready to use locally.
            $script:lastPing = Get-Date
            $sr = New-Object IO.StreamReader($ctx.Request.InputStream, [Text.Encoding]::UTF8)
            $body = $sr.ReadToEnd(); $sr.Close()
            $data = $body | ConvertFrom-Json
            Sync-Studio -Quiet
            $installed = New-Object System.Collections.Generic.List[object]
            $missing = New-Object System.Collections.Generic.List[object]
            foreach ($raw in @($data.ids)) {
                $id = [string]$raw
                if ($id -notmatch '^\d{5,}$') { continue }
                $p = Join-Path $LibDir "$id.mesh"
                if ((Test-Path $p) -and $TglInstall.IsChecked) {
                    if (-not $script:boundsCache.ContainsKey($id) -or -not $script:bonesCache.ContainsKey($id)) {
                        [byte[]]$mbytes = [IO.File]::ReadAllBytes($p)
                        $script:boundsCache[$id] = Get-MeshBounds $mbytes
                        $script:bonesCache[$id] = [int](Get-MeshStats $mbytes).bones
                    }
                    $installed.Add(@{ id = $id; size = $script:boundsCache[$id]; bones = $script:bonesCache[$id] })
                } else {
                    $missing.Add($id)
                }
            }
            Send-Json $ctx @{
                ok          = $true
                studioFound = ($script:studioDirs.Count -gt 0)
                inbox       = (Get-InboxDir)
                textures    = (Get-TextureMap)
                installOn   = [bool]$TglInstall.IsChecked
                installed   = [object[]]$installed.ToArray()
                missing     = [object[]]$missing.ToArray()
            }
            Log ("Studio asked for {0} mesh(es): {1} ready, {2} not downloaded." -f ($installed.Count + $missing.Count), $installed.Count, $missing.Count)
            return
        }
        if ($path -eq '/blender/mesh' -and $ctx.Request.HttpMethod -eq 'POST') { Receive-BlenderMesh $ctx; return }
        if ($path -eq '/blender/texture' -and $ctx.Request.HttpMethod -eq 'POST') { Receive-BlenderTexture $ctx; return }
        if ($path -eq '/blender/pose' -and $ctx.Request.HttpMethod -eq 'POST') { Receive-BlenderPose $ctx; return }
        if ($path -eq '/toblender' -and $ctx.Request.HttpMethod -eq 'POST') { $script:lastPing = Get-Date; Receive-ToBlender $ctx; return }
        if ($path -eq '/blender/incoming') {
            Check-ToBlenderWait
            $ev = [object[]]$script:toBlender.ToArray()
            $script:toBlender.Clear()
            Send-Json $ctx @{ ok = $true; events = $ev; waiting = $script:toBlenderWait.Count }
            return
        }
        if ($path -eq '/blender/file') {
            $kind = [string]$ctx.Request.QueryString['kind']
            $full = $null
            if ($kind -eq 'mesh') {
                $id = [string]$ctx.Request.QueryString['id']
                if ($id -match '^\d{5,}$') { $full = Join-Path $LibDir "$id.mesh" }
            } elseif ($kind -eq 'tex') {
                $n = [string]$ctx.Request.QueryString['name']
                if ($n -match '^[A-Za-z0-9_.-]+\.(png|jpg)$') { $full = Join-Path $TexDir $n }
            }
            if (-not $full -or -not (Test-Path -LiteralPath $full)) { Send-Json $ctx @{ ok = $false; error = 'not found' } 404; return }
            Send-Bytes $ctx ([IO.File]::ReadAllBytes($full)) 'application/octet-stream'
            return
        }
        if ($path -eq '/blender/next') {
            $script:lastPing = Get-Date
            $ev = [object[]]$script:blenderEvents.ToArray()
            $script:blenderEvents.Clear()
            Send-Json $ctx @{ ok = $true; events = $ev }
            return
        }
        if ($path -eq '/bake') {
            $script:lastPing = Get-Date
            $file = [string]$ctx.Request.QueryString['file']
            $color = ([string]$ctx.Request.QueryString['color']).ToLower()
            $tint = ([string]$ctx.Request.QueryString['tint']).ToLower()
            if ($file -notmatch '^[A-Za-z0-9_.-]+\.(png|jpg)$' -or $color -notmatch '^[0-9a-f]{6}$' -or ($tint -and $tint -notmatch '^[0-9a-f]{6}$')) {
                Send-Json $ctx @{ ok = $false; error = 'bad request' } 400; return
            }
            if ($script:studioDirs.Count -eq 0) { $script:studioDirs = @(Get-StudioContentDirs) }
            $baked = Bake-Texture $file $color $tint
            if ($baked) { Send-Json $ctx @{ ok = $true; file = $baked; created = [bool]$script:bakeCreated } } else { Send-Json $ctx @{ ok = $false; error = 'picture not downloaded' } 404 }
            return
        }
        if ($path -eq '/unbake' -and $ctx.Request.HttpMethod -eq 'POST') {
            # painted skin-colour pictures nothing uses any more (only names like x_c1a2b3c.png)
            $sr = New-Object IO.StreamReader($ctx.Request.InputStream, [Text.Encoding]::UTF8)
            $d = $sr.ReadToEnd() | ConvertFrom-Json; $sr.Close()
            if ($script:studioDirs.Count -eq 0) { $script:studioDirs = @(Get-StudioContentDirs) }
            $n = 0
            foreach ($f in @($d.files)) {
                $f = [string]$f
                if ($f -notmatch '^[A-Za-z0-9_.-]+_c[0-9a-f]{6}(_t[0-9a-f]{6})?\.png$') { continue }
                $places = @(Join-Path $TexDir $f)
                foreach ($sd in $script:studioDirs) { $places += (Join-Path $sd "meshtools\textures\$f"); $places += (Join-Path $sd "textures\meshtools\$f") }
                foreach ($pp in $places) { try { if (Test-Path -LiteralPath $pp) { Remove-Item -LiteralPath $pp -Force; $n++ } } catch { } }
            }
            if ($n -gt 0) { Log ("Cleaned up {0} old skin-colour picture file(s)." -f $n) }
            Send-Json $ctx @{ ok = $true; deleted = $n }
            return
        }
        if ($path -eq '/library') {
            $script:lastPing = Get-Date
            Send-Json $ctx (Get-LibraryData)
            return
        }
        if ($path -eq '/look') {
            $id = [string]$ctx.Request.QueryString['id']
            $chunk = 0
            [void][int]::TryParse([string]$ctx.Request.QueryString['chunk'], [ref]$chunk)
            $full = Join-Path $LookDir "$id.rbxm"
            if ($id -notmatch '^\d{5,}$' -or -not (Test-Path -LiteralPath $full)) { Send-Json $ctx @{ ok = $false; error = 'no look saved' } 404; return }
            Send-FileChunk $ctx $full $chunk
            return
        }
        if ($path -eq '/model') {
            # Sends a saved .rbxm to the plugin in base64 chunks (for the Inserter)
            $script:lastPing = Get-Date
            $key = $ctx.Request.QueryString['key']
            $chunk = 0
            [void][int]::TryParse([string]$ctx.Request.QueryString['chunk'], [ref]$chunk)
            $full = Resolve-SafeModelPath $key
            if (-not $full) { Send-Json $ctx @{ ok = $false; error = 'model file not found' } 404; return }
            if ($chunk -eq 0 -or $script:modelBytesCache.key -ne $full) {
                $script:modelBytesCache = @{ key = $full; bytes = [IO.File]::ReadAllBytes($full) }
            }
            [byte[]]$mb = $script:modelBytesCache.bytes
            $size = 524286   # multiple of 3, so every chunk is clean base64
            $count = [Math]::Max(1, [int][Math]::Ceiling($mb.Length / $size))
            if ($chunk -lt 0 -or $chunk -ge $count) { Send-Json $ctx @{ ok = $false; error = 'bad chunk' } 400; return }
            $start = $chunk * $size
            $len = [Math]::Min($size, $mb.Length - $start)
            Send-Json $ctx @{
                ok = $true; chunk = $chunk; count = $count; ext = [IO.Path]::GetExtension($full)
                data = [Convert]::ToBase64String($mb, $start, $len)
            }
            return
        }
        if ($path -eq '/savemodel' -and $ctx.Request.HttpMethod -eq 'POST') {
            # Plugin uploads a serialized model in base64 chunks; we write the .rbxm.
            $script:lastPing = Get-Date
            $sr = New-Object IO.StreamReader($ctx.Request.InputStream, [Text.Encoding]::UTF8)
            $body = $sr.ReadToEnd(); $sr.Close()
            $d = $body | ConvertFrom-Json
            $uid = [string]$d.id
            $idx = [int]$d.index
            $cnt = [int]$d.count
            if ($cnt -lt 1 -or $idx -lt 0 -or $idx -ge $cnt) { Send-Json $ctx @{ ok = $false; error = 'bad chunk' } 400; return }
            if (-not $script:uploads.ContainsKey($uid)) { $script:uploads[$uid] = @{ parts = (New-Object 'string[]' $cnt); got = 0 } }
            $up = $script:uploads[$uid]
            if ($null -eq $up.parts[$idx]) { $up.got++ }
            $up.parts[$idx] = [string]$d.data
            if ($up.got -lt $cnt) { Send-Json $ctx @{ ok = $true; done = $false }; return }

            $script:uploads.Remove($uid)
            [byte[]]$mb = [Convert]::FromBase64String(($up.parts -join ''))
            if ([string]$d.kind -eq 'mesh') {
                # a .mesh the plugin converted (e.g. from an .obj): library + Studio, ready to insert
                if (-not $TglInstall.IsChecked) { Send-Json $ctx @{ ok = $false; error = "Turn on 'Install meshes into Studio' in Mesh Downloader" } 409; return }
                if ($script:studioDirs.Count -eq 0) { $script:studioDirs = @(Get-StudioContentDirs) }
                if ($script:studioDirs.Count -eq 0) { Send-Json $ctx @{ ok = $false; error = "Mesh Downloader can't find Roblox Studio" } 409; return }
                if ($mb.Length -lt 25 -or [Text.Encoding]::ASCII.GetString($mb, 0, 8) -ne 'version ') { Send-Json $ctx @{ ok = $false; error = 'not a .mesh' } 400; return }
                $mid = New-BlenderId '7'
                Install-Mesh $mid $mb
                $mname = Clean-Field ([string]$d.name)
                if (-not $mname) { $mname = 'Imported mesh' }
                $entry = New-IndexEntry $mname $null $mb ((Get-Date).ToString('yyyy-MM-dd HH:mm'))
                $entry.source = 'obj'
                $script:index[$mid] = $entry
                Save-Index
                Log ("Imported {0} as local mesh {1} ({2})" -f $mname, $mid, (Format-Size $mb.Length))
                Send-Json $ctx @{ ok = $true; done = $true; id = $mid }
                return
            }
            if ([string]$d.kind -eq 'texture') {
                $tname = Install-Texture (New-BlenderId '6') $mb
                if (-not $tname) { Send-Json $ctx @{ ok = $false; error = 'texture must be a PNG or JPG' } 400; return }
                Send-Json $ctx @{ ok = $true; done = $true; file = $tname }
                return
            }
            if ([string]$d.kind -eq 'look') {
                $lid = [string]$d.name
                if ($lid -notmatch '^\d{5,}$') { Send-Json $ctx @{ ok = $false; error = 'bad id' } 400; return }
                if (-not (Test-Path $LookDir)) { New-Item -ItemType Directory -Path $LookDir -Force | Out-Null }
                [IO.File]::WriteAllBytes((Join-Path $LookDir "$lid.rbxm"), $mb)
                Send-Json $ctx @{ ok = $true; done = $true; path = "looks\$lid.rbxm" }
                return
            }
            $root = Get-SaveRoot
            if (-not $root) { Send-Json $ctx @{ ok = $false; error = 'no save folder set in Mesh Downloader' } 500; return }
            $sub = 'Models'
            if ([string]$d.kind -eq 'local') { $sub = 'Local Models' }
            $dir = Join-Path $root $sub
            $fold = Get-SafeName (Clean-Field ([string]$d.folder))
            if ($fold) { $dir = Join-Path $dir $fold }
            if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
            $name = Get-SafeName (Clean-Field ([string]$d.name))
            if (-not $name) { $name = 'Model' }
            $file = Join-Path $dir "$name.rbxm"
            $n = 2
            while (Test-Path -LiteralPath $file) { $file = Join-Path $dir "$name ($n).rbxm"; $n++ }
            [IO.File]::WriteAllBytes($file, $mb)
            $rel = $file.Substring($root.Length).TrimStart('\')
            Log ("Saved model {0} ({1})" -f $rel, (Format-Size $mb.Length))
            Send-Json $ctx @{ ok = $true; done = $true; path = $rel; full = $file }
            if ($TglOpen.IsChecked) { Start-Process explorer.exe "/select,`"$file`"" }
            return
        }
        if ($path -eq '/reveal') {
            $key = $ctx.Request.QueryString['key']
            $mesh = [string]$ctx.Request.QueryString['mesh']
            $target = $null
            if ($key) { $target = Resolve-SafeModelPath $key }
            elseif ($mesh -match '^\d{5,}$') {
                $e = $script:index[$mesh]
                $root = Get-SaveRoot
                if ($e -and $e.file -and $root) {
                    $p = Join-Path $root ([string]$e.file)
                    if (Test-Path -LiteralPath $p) { $target = $p }
                }
                if (-not $target) {
                    $p = Join-Path $LibDir "$mesh.mesh"
                    if (Test-Path -LiteralPath $p) { $target = $p }
                }
            }
            if ($target) { Start-Process explorer.exe "/select,`"$target`""; Send-Json $ctx @{ ok = $true } }
            else { Send-Json $ctx @{ ok = $false; error = 'file not found' } 404 }
            return
        }
        Send-Json $ctx @{ ok = $false; error = 'not found' } 404
    } catch {
        Send-Json $ctx @{ ok = $false; error = $_.Exception.Message } 500
    }
}

function Start-Link {
    if ($script:listener -and $script:listener.IsListening) { return }
    try {
        $script:listener = New-Object System.Net.HttpListener
        $script:listener.Prefixes.Add("http://localhost:$Port/")
        $script:listener.Start()
        $script:ctxTask = $script:listener.GetContextAsync()
        Set-Link 'on' 'Studio link: waiting for plugin'
    } catch {
        $script:listener = $null; $script:ctxTask = $null
        Set-Link 'err' "Studio link: port $Port is busy"
        Log ("Couldn't start the Studio link: {0}" -f $_.Exception.Message)
        Log 'Is another copy of Mesh Downloader already open?'
    }
}

function Stop-Link {
    if ($script:listener) { try { $script:listener.Stop(); $script:listener.Close() } catch { } }
    $script:listener = $null; $script:ctxTask = $null
    Set-Link 'off' 'Studio link: off'
}

$timer = New-Object System.Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromMilliseconds(150)
$timer.Add_Tick({
    # handle every request that's waiting (Blender poses + plugin polls can come several at a time)
    $handled = 0
    while ($script:ctxTask -and $script:ctxTask.IsCompleted -and $handled -lt 12) {
        $t = $script:ctxTask
        $script:ctxTask = $null
        if ($script:listener -and $script:listener.IsListening) { $script:ctxTask = $script:listener.GetContextAsync() }
        if ($t.Status -eq [System.Threading.Tasks.TaskStatus]::RanToCompletion) { Handle-Request $t.Result }
        $handled++
    }
    if ($script:listener -and $script:listener.IsListening) {
        if (((Get-Date) - $script:lastPing).TotalSeconds -lt 8) { Set-Link 'connected' 'Studio plugin connected' }
        else { Set-Link 'on' 'Studio link: waiting for plugin' }
    }
    # Every ~60 seconds, re-copy meshes in case Studio updated (updates wipe its content folder).
    $script:tickCount++
    if ($script:tickCount -eq 4) { Check-Updates }
    if ($script:tickCount % 400 -eq 0 -and -not $script:busy) { Sync-Studio -Quiet }
    if ($script:tickCount % 10 -eq 0 -and -not $script:busy) { Watch-Inbox }
    if ($script:autoStartPending -and -not $script:busy) { Run-Queue }
})

# ---------------- wire up the window ----------------
$settings = Load-Settings
$VersionText.Text = "v$AppVersion"
$KeyBox.Password = Load-ApiKey
$FolderBox.Text = [string]$settings.folder
$TglListen.IsChecked = [bool]$settings.listen
$TglOpen.IsChecked = [bool]$settings.openWhenDone
$TglFolders.IsChecked = [bool]$settings.useFolders
$TglInstall.IsChecked = [bool]$settings.installStudio
$TglCenterMesh.IsChecked = [bool]$settings.centerMesh
if (-not [string]$settings.updateUrl) { $settings.updateUrl = $DefaultUpdateUrl }
$UpdateBox.Text = [string]$settings.updateUrl
$script:shortcutFor = [string]$settings.shortcutFor
$RetriesBox.Text = [string]$settings.retries
$DelayBox.Text = [string]$settings.delay

$TitleBar.Add_MouseLeftButtonDown({ try { $window.DragMove() } catch { } })
$BtnMin.Add_Click({ $window.WindowState = 'Minimized' })
$BtnClose.Add_Click({
    if ($script:busy) { $script:stop = $true; $script:closeAfter = $true; Log 'Stopping, then closing...' }
    else { $window.Close() }
})

$IdsBox.Add_TextChanged({
    $IdsPlaceholder.Visibility = if ($IdsBox.Text.Length -gt 0) { 'Collapsed' } else { 'Visible' }
    $c = (Get-Entries $IdsBox.Text).Count
    if ($c -gt 0) { $QueueCount.Text = "$c ID(s) ready" }
    else { $QueueCount.Text = 'Mesh IDs, model IDs, rbxassetid:// links, or plugin lines' }
})

$BtnStart.Add_Click({ Run-Queue })
$BtnPause.Add_Click({
    $script:paused = -not $script:paused
    if ($script:paused) { $BtnPause.Content = 'Resume'; Log 'Paused.' }
    else { $BtnPause.Content = 'Pause'; Log 'Resumed.' }
})
$BtnStop.Add_Click({ $script:stop = $true; $script:paused = $false; Log 'Stopping after the current file...' })

$BtnOpen.Add_Click({
    $f = $FolderBox.Text.Trim()
    if (-not $f) { return }
    if (-not (Test-Path $f)) { New-Item -ItemType Directory -Path $f -Force | Out-Null }
    Start-Process explorer.exe $f
})
$BtnClearLog.Add_Click({ $LogBox.Clear() })

$BtnGetKey.Add_Click({ Start-Process 'https://create.roblox.com/dashboard/credentials' })
$KeyBox.Add_LostFocus({ $k = $KeyBox.Password.Trim(); if ($k) { Save-ApiKey $k } })

$BtnBrowse.Add_Click({
    $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
    $dlg.Description = 'Choose where to save downloaded files'
    if (Test-Path $FolderBox.Text) { $dlg.SelectedPath = $FolderBox.Text }
    if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { $FolderBox.Text = $dlg.SelectedPath; Save-Settings }
})

$TglListen.Add_Checked({ Start-Link; Save-Settings })
$TglListen.Add_Unchecked({ Stop-Link; Save-Settings })
$TglOpen.Add_Click({ Save-Settings })
$TglFolders.Add_Click({ Save-Settings })
$TglInstall.Add_Click({ Save-Settings; Sync-Studio })
$TglCenterMesh.Add_Click({ Save-Settings })
$BtnUpdate.Add_Click({ Save-Settings; Check-Updates -Manual })
$UpdateBox.Add_LostFocus({ Save-Settings })
$BtnConvert.Add_Click({
    $dlg = New-Object Microsoft.Win32.OpenFileDialog
    $dlg.Title = 'Choose .rbxmx model file(s) to make local'
    $dlg.Filter = 'Roblox XML model (*.rbxmx)|*.rbxmx|All files (*.*)|*.*'
    $dlg.Multiselect = $true
    if ($dlg.ShowDialog($window)) { foreach ($f in $dlg.FileNames) { [void](Convert-Rbxmx $f (Get-LocalOutDir)) } }
})

$window.AllowDrop = $true
$window.Add_PreviewDragOver({
    param($s, $e)
    if ($e.Data.GetDataPresent([System.Windows.DataFormats]::FileDrop)) {
        $e.Effects = [System.Windows.DragDropEffects]::Copy
        $e.Handled = $true
    }
})
$window.Add_PreviewDrop({
    param($s, $e)
    if ($e.Data.GetDataPresent([System.Windows.DataFormats]::FileDrop)) {
        $e.Handled = $true
        foreach ($f in @($e.Data.GetData([System.Windows.DataFormats]::FileDrop))) { [void](Convert-Rbxmx ([string]$f) (Get-LocalOutDir)) }
    }
})

$BtnSync.Add_Click({
    Sync-Studio
    if ($script:studioDirs.Count -eq 0) { Log "Couldn't find Roblox Studio in AppData - is it installed for this Windows user?" }
    else { Log ("Studio is up to date ({0} install folder(s) checked)." -f $script:studioDirs.Count) }
})

$window.Add_Closed({
    try { $script:appMutex.ReleaseMutex() } catch { }
    $timer.Stop()
    Stop-Link
    Save-Settings
    $k = $KeyBox.Password.Trim(); if ($k) { Save-ApiKey $k }
})

# ---------------- start ----------------
if ($TglListen.IsChecked) { Start-Link } else { Set-Link 'off' 'Studio link: off' }
Load-Index
Set-WindowIcon
Install-Shortcuts
Install-Plugin
Sync-Studio -Quiet
$timer.Start()

Log "Mesh Downloader v$AppVersion ready."
if (-not $KeyBox.Password) { Log 'First time? Paste your Open Cloud API key on the right (Get Key opens the page).' }
Log 'Paste IDs and press Start - or use Send in the Studio plugin.'
Log ''

[void]$window.ShowDialog()
