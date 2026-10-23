unit Demo.Password;

{ Password prompt for encrypted documents. }

interface

uses
  System.SysUtils, System.Types, System.UITypes, System.Classes,
  FMX.Types, FMX.Controls, FMX.Forms, FMX.StdCtrls, FMX.Edit, FMX.Controls.Presentation, FMX.Layouts;

type
  TPasswordForm = class(TForm)
    PromptLabel: TLabel;
    PasswordEdit: TEdit;
    ButtonLayout: TLayout;
    OkButton: TButton;
    CancelButton: TButton;
    ErrorLabel: TLabel;
    procedure PasswordEditKeyDown(Sender: TObject; var Key: Word; var KeyChar: WideChar; Shift: TShiftState);
    procedure FormShow(Sender: TObject);
  end;

/// <summary>Asks for the password of FileName; Attempt > 1 shows a "wrong password" notice. False when cancelled.</summary>
function AskPassword(const FileName: string; Attempt: Integer; out Password: string): Boolean;

implementation

{$R *.fmx}

function AskPassword(const FileName: string; Attempt: Integer; out Password: string): Boolean;
var
  F: TPasswordForm;
begin
  Password := '';
  F := TPasswordForm.Create(nil);
  try
    if Application.MainForm <> nil then
      F.StyleBook := Application.MainForm.StyleBook;
    F.PromptLabel.Text := Format('%s is beveiligd met een wachtwoord.', [ExtractFileName(FileName)]);
    F.ErrorLabel.Visible := Attempt > 1;
    Result := F.ShowModal = mrOk;
    if Result then
      Password := F.PasswordEdit.Text;
  finally
    F.Free;
  end;
end;

procedure TPasswordForm.FormShow(Sender: TObject);
begin
  PasswordEdit.SetFocus;
end;

procedure TPasswordForm.PasswordEditKeyDown(Sender: TObject; var Key: Word; var KeyChar: WideChar; Shift: TShiftState);
begin
  if Key = vkReturn then
  begin
    ModalResult := mrOk;
    Key := 0;
  end
  else if Key = vkEscape then
  begin
    ModalResult := mrCancel;
    Key := 0;
  end;
end;

end.
