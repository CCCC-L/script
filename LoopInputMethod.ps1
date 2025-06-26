# 切换当前用户使用的输入法
$inputMethodTips = @(
  "0804:{A3F4CDED-B1E9-41EE-9CA6-7B4D0DE6CB0A}{3D02CAB6-2B8E-4781-BA20-1C9267529467}" # Rime
  "0804:{81D4E9C9-1D3B-41BC-9E6C-4B40BF79E35E}{FA550B04-5AD7-411F-A5AC-CA038EC515D7}" # 微软
)

$wull = Get-WinUserLanguageList
$nextIndex = ($inputMethodTips.IndexOf($wull[0].inputMethodTips -as [string]) + 1) % $inputMethodTips.Length
$wull[0].inputMethodTips.clear()
$wull[0].inputMethodTips.add($inputMethodTips[$nextIndex])
Set-WinUserLanguageList $wull -Force

if ($nextIndex -eq 0) {
  Start-Process "C:\ProgramData\Microsoft\Windows\Start Menu\Programs\小狼毫输入法\小狼毫算法服务.lnk"
}
