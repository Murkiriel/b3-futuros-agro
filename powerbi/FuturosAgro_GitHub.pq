// Futuros agro da B3 (BGI, CCM, SJC) lidos do CSV que o GitHub Actions deste
// repositório atualiza todo dia útil. Não depende de Python nem de gateway.
//
// Power BI Desktop > Transformar dados > Nova Fonte > Consulta Nula > Editor Avançado >
// cole este arquivo > Concluído. Credencial: Anônimo. Privacidade: Público.
let
    Url = "https://raw.githubusercontent.com/Murkiriel/b3-futuros-agro/main/dados/b3_futuros_agro.csv",
    Fonte = Csv.Document(
        Web.Contents(Url, [Timeout = #duration(0, 0, 1, 0)]),
        [Delimiter = ",", Encoding = 65001, QuoteStyle = QuoteStyle.Csv]
    ),
    Cabecalho = Table.PromoteHeaders(Fonte, [PromoteAllScalars = true]),
    Datas = {"Data", "Vencimento"},
    Textos = {"Contrato", "Descrição", "Ticker", "Unidade", "Moeda Original", "Versão B3"},
    Inteiros = {"Nº Negócios", "Contratos Negociados", "Contratos em Aberto"},
    Tipos = List.Transform(
        Table.ColumnNames(Cabecalho),
        (c) => {
            c,
            if List.Contains(Datas, c) then type date
            else if List.Contains(Textos, c) then type text
            else if List.Contains(Inteiros, c) then Int64.Type
            else if c = "Oscilação" then Percentage.Type
            else type number
        }
    ),
    Tipada = Table.TransformColumnTypes(Cabecalho, Tipos, "en-US")
in
    Tipada
