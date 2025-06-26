param (
  [Parameter(Position = 0, Mandatory = $true)]
  [string]$path,
  [int]$pwdLength=10,
  [string]$output = $(Split-Path -Path $path -Parent),
  [string]$pwdOutput = $output,
  [string]$type = "zip"
)

function getPassword {
  $password = ""

  foreach($_ in 1..$pwdLength) {
    $char = [char](Get-Random -Minimum 33 -Maximum 126)
    $password += $char
  }

  return $password
}

if (-not (Test-Path $path)) {
  Write-Output "Cannot find path '$path' because it does not exist."
  exit
}

$fileName = $(Split-Path -Path $path -Leaf) -replace '\.[^.]+$'
$packagePath = $($output + "\" + $fileName)
$pwdOutputPath = $($pwdOutput + "\" + $fileName)

# 打包
$pwd = getPassword
7za a $($packagePath + ".$type") "-p$pwd" $path
Write-Output $pwd > $($pwdOutputPath + ".txt")

$pwd = getPassword
7za a $($packagePath + "1.$type") "-p$pwd" $($packagePath + ".$type")
Write-Output $pwd >> $($pwdOutputPath + ".txt")

# 删除第一次打包
Remove-Item $($packagePath + ".$type")
Rename-Item -Path $($packagePath + "1.$type") -NewName $($packagePath + ".$type")



