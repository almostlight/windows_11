
$ErrorActionPreference = 'Stop'

Add-Type @'
using System;
using System.Runtime.InteropServices;

public static class TaskbarControl {
	[DllImport("user32.dll")]
	public static extern IntPtr FindWindow(string className, string windowName);

	[DllImport("user32.dll")]
	public static extern bool ShowWindow(IntPtr hwnd, int command);

	[DllImport("user32.dll")]
	public static extern bool IsWindowVisible(IntPtr hwnd);
}
'@

$taskbar = [TaskbarControl]::FindWindow('Shell_TrayWnd', $null)

if ($taskbar -eq [IntPtr]::Zero) {
	throw 'Could not find the Windows taskbar.'
}

$wasVisible = [TaskbarControl]::IsWindowVisible($taskbar)

try {
	while (Get-Process -Name 'komorebi-bar' -ErrorAction SilentlyContinue) {
		[void][TaskbarControl]::ShowWindow($taskbar, 0)
		Start-Sleep -Milliseconds 500
	}
}
finally {
	[void][TaskbarControl]::ShowWindow($taskbar, $(if ($wasVisible) { 5 } else { 0 }))
}
