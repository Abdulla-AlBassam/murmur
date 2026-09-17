; Inno Setup script for Murmur. Built by build.ps1.
;
; Installs into the user's own profile, which means no administrator
; password and no UAC prompt: the person installing it just clicks Install.

#ifndef MyAppVersion
  #define MyAppVersion "0.1.0"
#endif

#define MyAppName "Murmur"
#define MyAppPublisher "Abdulla AlBassam"
#define MyAppExeName "Murmur.exe"

[Setup]
AppId={{8E2B1A54-6F3D-4C77-9E1B-4F6A2C9D7B10}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher={#MyAppPublisher}
DefaultDirName={localappdata}\Programs\{#MyAppName}
DefaultGroupName={#MyAppName}
DisableProgramGroupPage=yes
DisableDirPage=yes
PrivilegesRequired=lowest
OutputDir=dist
OutputBaseFilename=MurmurSetup-{#MyAppVersion}
SetupIconFile=murmur.ico
UninstallDisplayIcon={app}\{#MyAppExeName}
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
; Murmur is a tray app; closing the window does not close the app, so the
; installer has to shut a running copy down before replacing its files.
CloseApplications=yes
RestartApplications=no

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "Create a shortcut on the desktop"; GroupDescription: "Shortcuts:"
Name: "startupicon"; Description: "Start Murmur when I sign in"; GroupDescription: "Shortcuts:"

[Files]
Source: "dist\Murmur\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs
#ifdef IncludeModels
; The offline build ships the models next to the app rather than making the
; PC download them on first run.
Source: "dist\bundled-models\*"; DestDir: "{localappdata}\Murmur\models"; Flags: ignoreversion recursesubdirs createallsubdirs
#endif

[Icons]
Name: "{group}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"
Name: "{group}\Uninstall {#MyAppName}"; Filename: "{uninstallexe}"
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; Tasks: desktopicon
Name: "{userstartup}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; Tasks: startupicon

[Run]
Filename: "{app}\{#MyAppExeName}"; Description: "Start Murmur now"; Flags: nowait postinstall skipifsilent

[UninstallDelete]
; The app's own files go with the uninstaller. Settings, history and the
; dictionary are the user's and are left alone; the models are big and
; useless without the app, so they go.
Type: filesandordirs; Name: "{localappdata}\Murmur\models"

[Code]
function InitializeSetup(): Boolean;
var
  Version: TWindowsVersion;
begin
  GetWindowsVersionEx(Version);
  // faster-whisper and llama.cpp both want a 64-bit, reasonably current
  // Windows. 10 1809 is where the terminal and UTF-8 behaviour settle down.
  if (Version.Major < 10) then
  begin
    MsgBox('Murmur needs Windows 10 or 11.', mbError, MB_OK);
    Result := False;
    exit;
  end;
  Result := True;
end;
