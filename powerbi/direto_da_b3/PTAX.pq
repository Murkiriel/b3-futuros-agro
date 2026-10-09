// PTAX venda do Banco Central (série SGS 1). Se o Banco Central não responder, a tabela
// fica vazia e as colunas em moeda convertida ficam em branco, sem travar a atualização.
let
    Hoje = Date.From(DateTimeZone.SwitchZone(DateTimeZone.UtcNow(), -3)),
    Resposta = try List.Buffer(
        Json.Document(
            Web.Contents(
                "https://api.bcb.gov.br/dados/serie/bcdata.sgs.1/dados",
                [
                    Query = [
                        formato = "json",
                        dataInicial = Date.ToText(DataInicial, "dd/MM/yyyy"),
                        dataFinal = Date.ToText(Hoje, "dd/MM/yyyy")
                    ],
                    Timeout = #duration(0, 0, 1, 0)
                ]
            )
        )
    ),
    Lista = if Resposta[HasError] then {} else Resposta[Value],
    Tabela = Table.FromRecords(
        List.Transform(
            Lista,
            each [
                Data = #date(Number.From(Text.End([data], 4)), Number.From(Text.Middle([data], 3, 2)), Number.From(Text.Start([data], 2))),
                #"Dólar PTAX" = Number.FromText([valor], "en-US")
            ]
        ),
        type table [Data = date, #"Dólar PTAX" = number]
    )
in
    Tabela
