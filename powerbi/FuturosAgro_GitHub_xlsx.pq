// Futuros agro da B3 (BGI, CCM, SJC) lidos da planilha do release mais recente deste
// repositório, atualizado todo dia útil pelo GitHub Actions.
//
// Power BI Desktop > Transformar dados > Nova Fonte > Consulta Nula > Editor Avançado >
// cole este arquivo > Concluído. Credencial: Anônimo. Privacidade: Público.
let
    Url = "https://github.com/Murkiriel/b3-futuros-agro/releases/latest/download/b3_futuros_agro.xlsx",
    Arquivo = Excel.Workbook(Web.Contents(Url, [Timeout = #duration(0, 0, 1, 0)]), null, true),
    // A aba "Futuros Agro" guarda os dados numa tabela do Excel chamada FuturosAgro
    Tabela = Arquivo{[Item = "FuturosAgro", Kind = "Table"]}[Data],
    Datas = {"Data", "Vencimento"},
    Textos = {"Contrato", "Descrição", "Ticker", "Unidade", "Moeda Original", "Versão B3"},
    Inteiros = {"Nº Negócios", "Contratos Negociados", "Contratos em Aberto"},
    Tipos = List.Transform(
        Table.ColumnNames(Tabela),
        (c) => {
            c,
            if List.Contains(Datas, c) then type date
            else if List.Contains(Textos, c) then type text
            else if List.Contains(Inteiros, c) then Int64.Type
            else if c = "Oscilação" then Percentage.Type
            else type number
        }
    ),
    Tipada = Table.TransformColumnTypes(Tabela, Tipos, "en-US")
in
    Tipada
