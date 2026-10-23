unit Demo.PrintDialog;

{ Print options: printer, page range. }

interface

uses
  System.SysUtils, System.Types, System.UITypes, System.Classes, System.Math,
  FMX.Types, FMX.Controls, FMX.Forms, FMX.StdCtrls, FMX.Edit, FMX.ListBox, FMX.Controls.Presentation, FMX.Layouts;

type
  TPrintForm = class(TForm)
    PrinterLabel: TLabel;
    PrinterCombo: TComboBox;
    RangeLabel: TLabel;
    AllRadio: TRadioButton;
    CurrentRadio: TRadioButton;
    RangeRadio: TRadioButton;
    RangeLayout: TLayout;
    FromEdit: TEdit;
    ToLabel: TLabel;
    ToEdit: TEdit;
    ButtonLayout: TLayout;
    OkButton: TButton;
    CancelButton: TButton;
    procedure RangeEditChange(Sender: TObject);
  end;

/// <summary>Shows the print dialog; returns False when cancelled. First/Last are 0-based page indexes.</summary>
function ShowPrintDialog(const Printers: TArray<string>; ActivePrinter, PageCount, CurrentPage: Integer;
  out PrinterIndex, FirstPage, LastPage: Integer): Boolean;

implementation

{$R *.fmx}

function ShowPrintDialog(const Printers: TArray<string>; ActivePrinter, PageCount, CurrentPage: Integer;
  out PrinterIndex, FirstPage, LastPage: Integer): Boolean;
var
  F: TPrintForm;
  S: string;
  A, B: Integer;
begin
  PrinterIndex := -1;
  FirstPage := 0;
  LastPage := PageCount - 1;
  F := TPrintForm.Create(nil);
  try
    if Application.MainForm <> nil then
      F.StyleBook := Application.MainForm.StyleBook;
    for S in Printers do
      F.PrinterCombo.Items.Add(S);
    F.PrinterCombo.ItemIndex := ActivePrinter;
    F.CurrentRadio.Text := Format('Huidige pagina (%d)', [CurrentPage + 1]);
    F.FromEdit.Text := '1';
    F.ToEdit.Text := IntToStr(PageCount);
    F.AllRadio.IsChecked := True;
    Result := F.ShowModal = mrOk;
    if not Result then
      Exit;
    PrinterIndex := F.PrinterCombo.ItemIndex;
    if F.CurrentRadio.IsChecked then
    begin
      FirstPage := CurrentPage;
      LastPage := CurrentPage;
    end
    else if F.RangeRadio.IsChecked then
    begin
      A := StrToIntDef(F.FromEdit.Text, 1);
      B := StrToIntDef(F.ToEdit.Text, PageCount);
      FirstPage := EnsureRange(Min(A, B), 1, PageCount) - 1;
      LastPage := EnsureRange(Max(A, B), 1, PageCount) - 1;
    end;
  finally
    F.Free;
  end;
end;

procedure TPrintForm.RangeEditChange(Sender: TObject);
begin
  RangeRadio.IsChecked := True;
end;

end.
