// Um registro por dia útil desde DataInicial, com o boletim da B3 de cada dia.
// Consulta auxiliar: não precisa ser carregada no modelo.
let
    Hoje = Date.From(DateTimeZone.SwitchZone(DateTimeZone.UtcNow(), -3)),
    Dias = List.Select(
        List.Dates(DataInicial, Duration.Days(Hoje - DataInicial) + 1, #duration(1, 0, 0, 0)),
        each Date.DayOfWeek(_, Day.Monday) < 5
    ),
    Tabela = Table.FromList(Dias, Splitter.SplitByNothing(), type table [Data = date]),
    // Um dia com problema não impede os demais: o erro fica registrado em StatusDownload
    ComBoletim = Table.AddColumn(Tabela, "Resultado", each try fnBoletimSPRD([Data])),
    ComStatus = Table.AddColumn(
        ComBoletim,
        "Status",
        each
            if [Resultado][HasError] then "Erro"
            else if [Resultado][Value] = null then (if [Data] = Hoje then "Ainda não publicado" else "Sem pregão")
            else "OK",
        type text
    ),
    ComDetalhe = Table.AddColumn(
        ComStatus, "Detalhe", each if [Resultado][HasError] then [Resultado][Error][Message] else null, type text
    ),
    ComDados = Table.AddColumn(ComDetalhe, "Dados", each if [Status] = "OK" then [Resultado][Value] else null),
    Final = Table.RemoveColumns(ComDados, {"Resultado"})
in
    Final
