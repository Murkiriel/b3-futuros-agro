// Tabela final: ajustes, preços (R$ e US$), negócios e contratos em aberto dos futuros
// de ConfigContratos. A moeda que a B3 não usa no contrato é convertida pela PTAX do dia.
let
    TipoLinha = type table [
        Data = date, Contrato = text, Ticker = text, Vencimento = date, Moeda = text,
        Ajuste = nullable number, AjusteAnterior = nullable number, Abertura = nullable number,
        Minimo = nullable number, Maximo = nullable number, Medio = nullable number,
        Ultimo = nullable number, Negocios = nullable number, ContratosEmAberto = nullable number,
        VersaoB3 = text
    ],
    Tabelas = List.RemoveNulls(Table.SelectRows(BaseDias, each [Status] = "OK")[Dados]),
    Linhas = if List.IsEmpty(Tabelas) then #table(TipoLinha, {}) else Table.Combine(Tabelas),

    ComContrato = Table.ExpandTableColumn(
        Table.NestedJoin(Linhas, "Contrato", ConfigContratos, "Contrato", "Cfg", JoinKind.LeftOuter),
        "Cfg", {"Descrição", "Unidade", "Tamanho"}
    ),
    ComPtax = Table.ExpandTableColumn(
        Table.NestedJoin(ComContrato, "Data", PTAX, "Data", "Ptax", JoinKind.LeftOuter),
        "Ptax", {"Dólar PTAX"}
    ),
    ComVariacao = Table.AddColumn(
        ComPtax, "Variacao",
        each if [Ajuste] = null or [AjusteAnterior] = null then null else Number.Round([Ajuste] - [AjusteAnterior], 6),
        type nullable number
    ),

    // Converte da moeda do contrato para a moeda pedida
    Converter = (linha as record, valor as nullable number, destino as text) as nullable number =>
        if valor = null then null
        else if linha[Moeda] = destino then valor
        else if linha[#"Dólar PTAX"] = null then null
        else if destino = "BRL" then valor * linha[#"Dólar PTAX"]
        else valor / linha[#"Dólar PTAX"],
    Precos = {
        {"Ajuste", "Ajuste"},
        {"AjusteAnterior", "Ajuste Anterior"},
        {"Variacao", "Variação"},
        {"Abertura", "Abertura"},
        {"Minimo", "Mínimo"},
        {"Maximo", "Máximo"},
        {"Medio", "Médio"},
        {"Ultimo", "Último"}
    },
    ComMoedas = List.Accumulate(
        Precos,
        ComVariacao,
        (t, p) =>
            Table.AddColumn(
                Table.AddColumn(t, p{1} & " (R$)", (r) => Converter(r, Record.Field(r, p{0}), "BRL"), type nullable number),
                p{1} & " (US$)", (r) => Converter(r, Record.Field(r, p{0}), "USD"), type nullable number
            )
    ),
    ComPorContrato = Table.AddColumn(
        Table.AddColumn(
            ComMoedas, "R$ por Contrato",
            each if [#"Variação (R$)"] = null then null else [#"Variação (R$)"] * [Tamanho], type nullable number
        ),
        "US$ por Contrato",
        each if [#"Variação (US$)"] = null then null else [#"Variação (US$)"] * [Tamanho], type nullable number
    ),
    Renomeada = Table.RenameColumns(
        ComPorContrato,
        {
            {"Moeda", "Moeda Original"},
            {"Negocios", "Nº Negócios"},
            {"ContratosEmAberto", "Contratos em Aberto"},
            {"VersaoB3", "Versão B3"}
        }
    ),
    Final = Table.TransformColumnTypes(
        Table.SelectColumns(
            Renomeada,
            {
                "Data", "Contrato", "Descrição", "Ticker", "Vencimento", "Unidade", "Moeda Original", "Dólar PTAX",
                "Ajuste (R$)", "Ajuste (US$)", "Ajuste Anterior (R$)", "Ajuste Anterior (US$)",
                "Variação (R$)", "Variação (US$)", "R$ por Contrato", "US$ por Contrato",
                "Abertura (R$)", "Abertura (US$)", "Mínimo (R$)", "Mínimo (US$)",
                "Máximo (R$)", "Máximo (US$)", "Médio (R$)", "Médio (US$)",
                "Último (R$)", "Último (US$)", "Nº Negócios", "Contratos em Aberto", "Versão B3"
            }
        ),
        {{"Nº Negócios", Int64.Type}, {"Contratos em Aberto", Int64.Type}},
        "en-US"
    )
in
    Final
