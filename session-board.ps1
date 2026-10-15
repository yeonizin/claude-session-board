Add-Type -AssemblyName PresentationFramework

$Root = if ($env:CLAUDE_CONFIG_DIR) { $env:CLAUDE_CONFIG_DIR } else { Join-Path $HOME '.claude' }
$StarFile = Join-Path $Root 'session-board.json'
$Starred = New-Object 'System.Collections.Generic.HashSet[string]'
if (Test-Path $StarFile) { @((Get-Content $StarFile -Raw -Encoding UTF8 | ConvertFrom-Json).starred) | Where-Object { $_ } | ForEach-Object { [void]$Starred.Add($_) } }

$Cache = @{}

# Transcripts are append-only and can reach several MB, so only the bytes added since the last poll are parsed.
function Update-Transcript($file) {
    $st = $Cache[$file.FullName]
    if (-not $st -or $file.Length -lt $st.Offset) {
        $st = @{ Offset = 0; Cwd = $null; Title = $null; Prompt = $null; First = $null; Last = $null; Usage = @{}; Ctx = 0; MaxCtx = 0 }
        $Cache[$file.FullName] = $st
    }
    if ($file.Length -eq $st.Offset) { return $st }

    $fs = [IO.File]::Open($file.FullName, 'Open', 'Read', 'ReadWrite')
    try {
        [void]$fs.Seek($st.Offset, 'Begin')
        $buf = (New-Object IO.BinaryReader($fs)).ReadBytes([int]($fs.Length - $st.Offset))
    } finally { $fs.Close() }
    $end = [Array]::LastIndexOf($buf, [byte]10)
    if ($end -lt 0) { return $st }
    $st.Offset += $end + 1

    foreach ($line in [Text.Encoding]::UTF8.GetString($buf, 0, $end + 1).Split("`n")) {
        # Quotes inside JSON string values are escaped, so a raw "key":" match is always a real key.
        $m = [regex]::Match($line, '"timestamp":"([^"]+)"', 'RightToLeft')
        if ($m.Success) {
            $t = [DateTime]::Parse($m.Groups[1].Value)
            if (-not $st.First) { $st.First = $t }
            $st.Last = $t
        }
        if (-not $st.Cwd -and $line -match '"cwd":"((?:[^"\\]|\\.)*)"') {
            $st.Cwd = ConvertFrom-Json "`"$($matches[1])`""
        }
        if ($line.Contains('"type":"ai-title"') -and $line -match '"aiTitle":"((?:[^"\\]|\\.)*)"') {
            $st.Title = ConvertFrom-Json "`"$($matches[1])`""
        }
        elseif (-not $st.Prompt -and $line.Contains('"type":"user"') -and $line -match '"content":\[\{"type":"text","text":"((?:[^"\\]|\\.)*)"' -and -not $matches[1].StartsWith('<')) {
            $st.Prompt = ConvertFrom-Json "`"$($matches[1])`""
        }
        elseif ($line.Contains('"type":"assistant"') -and $line -match '"id":"(msg_[^"]+)"') {
            # One response is written as one line per content block, each repeating the same usage.
            $id = $matches[1]
            $i = $line.IndexOf('"usage":{')
            if ($i -lt 0) { continue }
            $u = $line.Substring($i)
            $n = foreach ($k in 'input_tokens', 'cache_creation_input_tokens', 'cache_read_input_tokens', 'output_tokens') {
                if ($u -match "`"$k`":(\d+)") { [long]$matches[1] } else { 0 }
            }
            $st.Usage[$id] = $n[0] + $n[1] + $n[3]
            $st.Ctx = $n[0] + $n[1] + $n[2]
            if ($st.Ctx -gt $st.MaxCtx) { $st.MaxCtx = $st.Ctx }
        }
    }
    $st
}

function Format-Tokens($n) {
    if ($n -ge 1e6) { '{0:N1}M' -f ($n / 1e6) } elseif ($n -ge 1e3) { '{0:N0}k' -f ($n / 1e3) } else { "$n" }
}

function Format-Span($ts) {
    if ($ts.TotalHours -ge 1) { '{0}h {1}m' -f [int][Math]::Floor($ts.TotalHours), $ts.Minutes } else { '{0}m' -f [int]$ts.TotalMinutes }
}

function Get-Rows {
    $live = @{}
    foreach ($f in Get-ChildItem (Join-Path $Root 'sessions') -Filter *.json -ErrorAction SilentlyContinue) {
        $s = Get-Content $f.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
        if (Get-Process -Id $s.pid -ErrorAction SilentlyContinue) { $live[$s.sessionId] = $s.status }
    }

    $from = $View.Day
    $to = $from.AddDays(1)
    $rows = foreach ($f in Get-ChildItem (Join-Path $Root 'projects') -Directory | Get-ChildItem -Filter *.jsonl -File) {
        if ($f.LastWriteTime -lt $from) { continue }
        $st = Update-Transcript $f
        if (-not $st.First -or $st.First -ge $to -or $st.Last -lt $from) { continue }
        $id = $f.BaseName
        $status = $live[$id]
        $end = if ($status -eq 'busy') { Get-Date } else { $st.Last }
        # ponytail: transcripts don't record the context window size; anything that ever exceeded 200k is assumed 1M.
        $window = if ($st.MaxCtx -gt 200000) { 1000000 } else { 200000 }
        $tokens = ($st.Usage.Values | Measure-Object -Sum).Sum
        $title = if ($st.Title) { $st.Title } elseif ($st.Prompt) { $st.Prompt } else { $f.Directory.Name }
        $icon = if ($status -and $Icons[$status]) { $Icons[$status] } else { $Icons.closed }
        $star = $Starred.Contains($id)
        [pscustomobject]@{
            Id        = $id
            Cwd       = $st.Cwd
            Title     = ($title -replace '\s+', ' ')
            Starred   = $star
            StarGlyph = if ($star) { [char]0xE735 } else { [char]0xE734 }
            StarColor = if ($star) { '#F2C55C' } else { '#6F737A' }
            Icon      = $icon[0]
            IconColor = $icon[1]
            Meta      = '{0} tok · {1}' -f (Format-Tokens $tokens), (Format-Span ($end - $st.First))
            Pct       = '{0}%' -f [int](100 * $st.Ctx / $window)
            Ctx       = [Math]::Min(100.0, 100 * $st.Ctx / $window)
            Opacity   = if ($status) { 1.0 } else { 0.5 }
            Sort      = $st.Last
        }
    }
    @($rows | Sort-Object @{ Expression = 'Starred'; Descending = $true }, @{ Expression = 'Sort'; Descending = $true })
}

$View = @{ Day = (Get-Date).Date; Month = $null }
$Icons = @{
    busy    = [char]0xEA3B, '#3574F0'
    idle    = [char]0xE73E, '#5FB865'
    waiting = [char]0xE7BA, '#F2C55C'
    closed  = [char]0xEA3A, '#6F737A'
}
$Ko = [Globalization.CultureInfo]'ko-KR'

[xml]$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Claude Sessions" Width="360" MaxHeight="520" SizeToContent="Height" Topmost="True"
        WindowStyle="None" AllowsTransparency="True" ResizeMode="NoResize" Background="Transparent"
        Foreground="#DFE1E5" FontFamily="Segoe UI" FontSize="12" TextOptions.TextFormattingMode="Display">
  <Window.Resources>
    <FontFamily x:Key="Icons">Segoe Fluent Icons, Segoe MDL2 Assets</FontFamily>
    <Style x:Key="Flat" TargetType="Button">
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="Foreground" Value="#DFE1E5"/>
      <Setter Property="Padding" Value="4,2"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Focusable" Value="False"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border Name="B" Background="{TemplateBinding Background}" CornerRadius="4" Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="B" Property="Background" Value="#43454A"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="Row" TargetType="Border">
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Style.Triggers>
        <Trigger Property="IsMouseOver" Value="True"><Setter Property="Background" Value="#35373B"/></Trigger>
      </Style.Triggers>
    </Style>
    <Style TargetType="ScrollBar">
      <Setter Property="Width" Value="6"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ScrollBar">
            <Track Name="PART_Track" IsDirectionReversed="True">
              <Track.Thumb>
                <Thumb><Thumb.Template><ControlTemplate><Border Background="#4E5157" CornerRadius="3"/></ControlTemplate></Thumb.Template></Thumb>
              </Track.Thumb>
            </Track>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
  </Window.Resources>

  <Border Background="#2B2D30" BorderBrush="#43454A" BorderThickness="1" CornerRadius="8">
    <DockPanel>
      <Border DockPanel.Dock="Top" Padding="12,6,6,6" BorderBrush="#1E1F22" BorderThickness="0,0,0,1">
        <Grid>
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/>
            <ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/>
          </Grid.ColumnDefinitions>
          <TextBlock Text="Claude Sessions" FontWeight="SemiBold" VerticalAlignment="Center"/>
          <Border Grid.Column="1" Background="#393B40" CornerRadius="8" Padding="6,0" Margin="6,0,0,0" VerticalAlignment="Center">
            <TextBlock Name="Count" FontSize="11" Foreground="#A8ADBD"/>
          </Border>
          <Button Name="DateBtn" Grid.Column="3" Style="{StaticResource Flat}" Padding="6,3">
            <StackPanel Orientation="Horizontal">
              <TextBlock Text="&#xE787;" FontFamily="{StaticResource Icons}" FontSize="12" Foreground="#A8ADBD" VerticalAlignment="Center"/>
              <TextBlock Name="DateLabel" Margin="6,0,0,0" Foreground="#A8ADBD" VerticalAlignment="Center"/>
            </StackPanel>
          </Button>
          <Button Name="CloseBtn" Grid.Column="4" Style="{StaticResource Flat}" Width="24" Height="24" Margin="2,0,0,0">
            <TextBlock Text="&#xE8BB;" FontFamily="{StaticResource Icons}" FontSize="9" Foreground="#A8ADBD"/>
          </Button>
          <Popup Name="Cal" PlacementTarget="{Binding ElementName=DateBtn}" Placement="Top" StaysOpen="False" AllowsTransparency="True">
            <Border Background="#2B2D30" BorderBrush="#43454A" BorderThickness="1" CornerRadius="6" Padding="8" Margin="0,0,0,4">
              <StackPanel Width="238">
                <Grid Margin="0,0,0,6">
                  <Button Name="PrevMonth" Style="{StaticResource Flat}" HorizontalAlignment="Left" Width="24" Height="24">
                    <TextBlock Text="&#xE76B;" FontFamily="{StaticResource Icons}" FontSize="10"/>
                  </Button>
                  <TextBlock Name="MonthLabel" FontWeight="SemiBold" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                  <Button Name="NextMonth" Style="{StaticResource Flat}" HorizontalAlignment="Right" Width="24" Height="24">
                    <TextBlock Text="&#xE76C;" FontFamily="{StaticResource Icons}" FontSize="10"/>
                  </Button>
                </Grid>
                <UniformGrid Columns="7" TextElement.Foreground="#6F737A" Margin="0,0,0,2">
                  <TextBlock Text="일" HorizontalAlignment="Center"/><TextBlock Text="월" HorizontalAlignment="Center"/>
                  <TextBlock Text="화" HorizontalAlignment="Center"/><TextBlock Text="수" HorizontalAlignment="Center"/>
                  <TextBlock Text="목" HorizontalAlignment="Center"/><TextBlock Text="금" HorizontalAlignment="Center"/>
                  <TextBlock Text="토" HorizontalAlignment="Center"/>
                </UniformGrid>
                <UniformGrid Name="Days" Columns="7" Rows="6"/>
                <Button Name="TodayBtn" Style="{StaticResource Flat}" Content="오늘" Foreground="#548AF7" HorizontalAlignment="Right" Padding="8,3" Margin="0,4,0,0"/>
              </StackPanel>
            </Border>
          </Popup>
        </Grid>
      </Border>

      <TextBlock Name="Empty" DockPanel.Dock="Top" Text="이 날짜의 세션이 없습니다" Foreground="#6F737A" HorizontalAlignment="Center" Margin="0,24"/>

      <ScrollViewer VerticalScrollBarVisibility="Auto" Margin="0,4,0,6">
        <ItemsControl Name="List">
          <ItemsControl.ItemTemplate>
            <DataTemplate>
              <Border Style="{StaticResource Row}" Padding="12,7,8,8" Opacity="{Binding Opacity}">
                <Grid>
                  <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="20"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/>
                  </Grid.ColumnDefinitions>
                  <Grid.RowDefinitions>
                    <RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/>
                  </Grid.RowDefinitions>
                  <TextBlock Text="{Binding Icon}" Foreground="{Binding IconColor}" FontFamily="{StaticResource Icons}" FontSize="11" VerticalAlignment="Center"/>
                  <TextBlock Grid.Column="1" Text="{Binding Title}" ToolTip="{Binding Title}" FontSize="13" TextTrimming="CharacterEllipsis" VerticalAlignment="Center"/>
                  <Button Name="Star" Grid.Column="2" Style="{StaticResource Flat}" Tag="{Binding Id}" Margin="6,0,0,0" ToolTip="중요 표시">
                    <TextBlock Text="{Binding StarGlyph}" Foreground="{Binding StarColor}" FontFamily="{StaticResource Icons}" FontSize="12"/>
                  </Button>
                  <Grid Grid.Row="1" Grid.Column="1" Margin="0,1,0,0">
                    <TextBlock Text="{Binding Meta}" Foreground="#868A91" FontSize="11"/>
                    <TextBlock Text="{Binding Pct}" Foreground="#868A91" FontSize="11" HorizontalAlignment="Right"/>
                  </Grid>
                  <ProgressBar Grid.Row="2" Grid.Column="1" Value="{Binding Ctx}" Maximum="100" Height="2" Margin="0,4,0,0"
                               Background="#393B40" Foreground="#3574F0" BorderThickness="0"/>
                </Grid>
              </Border>
            </DataTemplate>
          </ItemsControl.ItemTemplate>
        </ItemsControl>
      </ScrollViewer>
    </DockPanel>
  </Border>
</Window>
'@

$win = [Windows.Markup.XamlReader]::Load((New-Object Xml.XmlNodeReader $xaml))
$ui = @{}
'List', 'Count', 'DateBtn', 'DateLabel', 'CloseBtn', 'Cal', 'PrevMonth', 'NextMonth', 'MonthLabel', 'Days', 'TodayBtn', 'Empty' |
    ForEach-Object { $ui[$_] = $win.FindName($_) }
$Brush = New-Object Windows.Media.BrushConverter

$refresh = {
    $rows = Get-Rows
    $ui.List.ItemsSource = $rows
    $ui.Count.Text = $rows.Count
    $ui.Empty.Visibility = if ($rows.Count) { 'Collapsed' } else { 'Visible' }
    $label = $View.Day.ToString('M월 d일 (ddd)', $Ko)
    $ui.DateLabel.Text = if ($View.Day -eq (Get-Date).Date) { "오늘 · $label" } else { $label }
}

function Show-Month {
    $m = $View.Month
    $ui.MonthLabel.Text = $m.ToString('yyyy년 M월', $Ko)
    $ui.Days.Children.Clear()
    for ($i = 0; $i -lt [int]$m.DayOfWeek; $i++) { [void]$ui.Days.Children.Add((New-Object Windows.Controls.Border)) }
    $today = (Get-Date).Date
    for ($d = $m; $d.Month -eq $m.Month; $d = $d.AddDays(1)) {
        $b = New-Object Windows.Controls.Button
        $b.Style = $win.Resources['Flat']
        $b.Content = $d.Day
        $b.Tag = $d
        $b.Height = 28
        if ($d -eq $View.Day) { $b.Background = $Brush.ConvertFrom('#3574F0'); $b.Foreground = $Brush.ConvertFrom('#FFFFFF') }
        elseif ($d -eq $today) { $b.Foreground = $Brush.ConvertFrom('#548AF7'); $b.FontWeight = 'Bold' }
        if ($d -gt $today) { $b.IsEnabled = $false; $b.Opacity = 0.35 }
        $b.Add_Click($pickDay)
        [void]$ui.Days.Children.Add($b)
    }
}

$pickDay = {
    param($s)
    $View.Day = $s.Tag
    $ui.Cal.IsOpen = $false
    & $refresh
}

$ui.DateBtn.Add_Click({
    $View.Month = $View.Day.AddDays(1 - $View.Day.Day)
    Show-Month
    $ui.Cal.IsOpen = $true
})
$ui.PrevMonth.Add_Click({ $View.Month = $View.Month.AddMonths(-1); Show-Month })
$ui.NextMonth.Add_Click({ $View.Month = $View.Month.AddMonths(1); Show-Month })
$ui.TodayBtn.Add_Click({ $View.Day = (Get-Date).Date; $ui.Cal.IsOpen = $false; & $refresh })
$ui.CloseBtn.Add_Click({ $win.Close() })

$win.AddHandler([Windows.Controls.Primitives.ButtonBase]::ClickEvent, [Windows.RoutedEventHandler]{
    param($s, $e)
    if ($e.OriginalSource.Name -ne 'Star') { return }
    $id = $e.OriginalSource.Tag
    if (-not $Starred.Remove($id)) { [void]$Starred.Add($id) }
    @{ starred = @($Starred) } | ConvertTo-Json | Set-Content $StarFile -Encoding UTF8
    & $refresh
})

# Star buttons mark MouseLeftButtonUp as handled, so this only fires for clicks elsewhere on a row.
$win.AddHandler([Windows.UIElement]::MouseLeftButtonUpEvent, [Windows.Input.MouseButtonEventHandler]{
    param($s, $e)
    $row = $e.OriginalSource.DataContext
    if (-not $row -or -not ($row.Id -as [guid])) { return }
    # The extension's URI is handled by whichever VS Code window was focused last, so the session's folder is focused first.
    if ($row.Cwd -and (Test-Path -LiteralPath $row.Cwd -PathType Container)) {
        Start-Process code -ArgumentList "`"$($row.Cwd)`"" -WindowStyle Hidden
        # ponytail: fixed wait for the window switch, poll the foreground window if 800ms proves flaky.
        Start-Sleep -Milliseconds 800
    }
    Start-Process "vscode://anthropic.claude-code/open?session=$($row.Id)"
})

# The window hugs its content, so it is re-anchored to the bottom-right whenever the list grows or shrinks.
$win.Add_SizeChanged({
    $area = [Windows.SystemParameters]::WorkArea
    $win.Left = $area.Right - $win.ActualWidth - 8
    $win.Top = $area.Bottom - $win.ActualHeight - 8
})

$timer = New-Object Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromSeconds(5)
$timer.Add_Tick($refresh)
$timer.Start()

& $refresh
[void]$win.ShowDialog()
