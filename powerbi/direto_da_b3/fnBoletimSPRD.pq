// Baixa o boletim simplificado da B3 (SPRDaammdd.zip / BVBG.187) de um pregão e devolve
// os vencimentos dos contratos de ConfigContratos, na versão final publicada no dia.
// Devolve null quando a B3 não tem boletim para a data (feriado ou ainda não publicado).
(Data as date) as nullable table =>
let
    NomeArquivo = "SPRD" & Date.ToText(Data, "yyMMdd") & ".zip",
    Baixar = (ignorarCache as logical) as binary =>
        Binary.Buffer(
            Web.Contents(
                "https://www.b3.com.br/pesquisapregao/download",
                [Query = [filelist = NomeArquivo], IsRetry = ignorarCache, Timeout = #duration(0, 0, 0, 30)]
            )
        ),

    // O ZIP da B3 traz outro ZIP dentro, com uma ou mais versões do XML
    AbrirXmls = (zip as binary) as table =>
        let
            Arquivos = Table.Combine(
                List.Transform(
                    Table.ToRecords(fnDescompactarZip(zip)),
                    (r) =>
                        if Text.EndsWith(Text.Lower(r[Nome]), ".zip") then fnDescompactarZip(r[Conteudo])
                        else Table.FromRecords({r}, type table [Nome = text, Conteudo = binary])
                )
            ),
            Xmls = Table.SelectRows(Arquivos, each Text.EndsWith(Text.Lower([Nome]), ".xml")),
            Carregados = Table.Buffer(Table.TransformColumns(Xmls, {"Conteudo", Binary.Buffer}))
        in
            if Table.IsEmpty(Carregados) then error "ZIP da B3 sem XML" else Carregados,

    // A B3 devolve, ao acaso, cerca de 1 em cada 4 pedidos com o ZIP vazio (mesmo em dia
    // com pregão), às vezes entrega o ZIP corrompido e às vezes não responde. Nos três
    // casos baixa de novo; só ZIP vazio em todas as tentativas vira feriado/não publicado.
    MaxTentativas = 6,
    Tentar = (tentativa as number) =>
        let
            Resposta = try (
                if tentativa = 1 then Baixar(false)
                else Function.InvokeAfter(() => Baixar(true), #duration(0, 0, 0, 2 * tentativa))
            ),
            Zip = if Resposta[HasError] then null else Resposta[Value],
            Vazio = Zip <> null and Binary.Length(Zip) < 1000,
            Aberto = if Zip = null or Vazio then null else try AbrirXmls(Zip),
            Motivo =
                if Resposta[HasError] then "a B3 não respondeu (" & Resposta[Error][Message] & ")"
                else if Aberto <> null then "arquivo inválido (" & Aberto[Error][Message] & ")"
                else ""
        in
            if Aberto <> null and not Aberto[HasError] then Aberto[Value]
            else if tentativa < MaxTentativas then @Tentar(tentativa + 1)
            else if Vazio then null
            else error "Boletim " & NomeArquivo & " não obtido em " & Text.From(MaxTentativas)
                & " tentativas: " & Motivo,

    Xmls = Tentar(1),

    // A B3 republica o boletim no mesmo dia; fica a versão gerada por último
    ComVersao = Table.AddColumn(
        Xmls,
        "VersaoB3",
        each Text.BetweenDelimiters(
            Text.FromBinary(Binary.Range([Conteudo], 0, 4096), TextEncoding.Utf8),
            "<CreDtAndTm>",
            "</CreDtAndTm>"
        ),
        type text
    ),
    Final = Table.Sort(ComVersao, {{"VersaoB3", Order.Descending}, {"Nome", Order.Descending}}){0},

    // Navegação no XML
    Folha = (v) => if Value.Is(v, type table) then (if Table.IsEmpty(v) then null else v{0}[Value]) else v,
    Filhos = (no as record, nome as text) as list => Table.ToRecords(Table.SelectRows(no[Value], each [Name] = nome)),
    Texto = (no as record, nome as text) =>
        let f = Filhos(no, nome) in if List.IsEmpty(f) then null else Folha(f{0}[Value]),
    Raiz = Xml.Document(Final[Conteudo]){0},
    Xchg = Filhos(Filhos(Raiz, "BizFileHdr"){0}, "Xchg"){0},
    Precos = List.Transform(Filhos(Xchg, "BizGrp"), each Filhos(Filhos(_, "Document"){0}, "PricRpt"){0}),

    // Só futuros dos contratos escolhidos (ex.: BGIX26) e só linhas da data do pregão
    Contratos = List.Buffer(ConfigContratos[Contrato]),
    Meses = "FGHJKMNQUVXZ",
    DataTexto = Date.ToText(Data, "yyyy-MM-dd"),
    EhFuturo = (t as nullable text) as logical =>
        t <> null
        and Text.Length(t) = 6
        and List.Contains(Contratos, Text.Start(t, 3))
        and Text.Contains(Meses, Text.Middle(t, 3, 1))
        and List.AllTrue(List.Transform(Text.ToList(Text.End(t, 2)), each Text.Contains("0123456789", _))),
    Selecionados = List.Select(
        Precos,
        each EhFuturo(Texto(Filhos(_, "SctyId"){0}, "TckrSymb")) and Texto(Filhos(_, "TradDt"){0}, "Dt") = DataTexto
    ),

    Num = (v) => if v = null then null else Number.FromText(v, "en-US"),
    Linha = (p as record) as record =>
        let
            Ticker = Texto(Filhos(p, "SctyId"){0}, "TckrSymb"),
            Atributos = Filhos(p, "FinInstrmAttrbts"){0}[Value],
            Campos = Record.FromList(List.Transform(Atributos[Value], Folha), Atributos[Name]),
            Valor = (nome as text) => Num(Record.FieldOrDefault(Campos, nome, null)),
            ComMoeda = List.Select(
                Atributos[Attributes],
                each _ <> null and Value.Is(_, type table) and List.Contains(_[Name], "Ccy")
            ),
            Moeda = if List.IsEmpty(ComMoeda) then null else Table.SelectRows(ComMoeda{0}, each [Name] = "Ccy"){0}[Value]
        in
            [
                Data = Data,
                Contrato = Text.Start(Ticker, 3),
                Ticker = Ticker,
                Vencimento = #date(2000 + Number.From(Text.End(Ticker, 2)), Text.PositionOf(Meses, Text.Middle(Ticker, 3, 1)) + 1, 1),
                Moeda = Moeda,
                Ajuste = Valor("AdjstdQt"),
                AjusteAnterior = Valor("PrvsAdjstdQt"),
                Abertura = Valor("FrstPric"),
                Minimo = Valor("MinPric"),
                Maximo = Valor("MaxPric"),
                Medio = Valor("TradAvrgPric"),
                Ultimo = Valor("LastPric"),
                Negocios = Valor("RglrTxsQty"),
                ContratosEmAberto = Valor("OpnIntrst"),
                VersaoB3 = Final[VersaoB3]
            ],
    Resultado = Table.FromRecords(
        List.Transform(Selecionados, Linha),
        type table [
            Data = date, Contrato = text, Ticker = text, Vencimento = date, Moeda = text,
            Ajuste = nullable number, AjusteAnterior = nullable number, Abertura = nullable number,
            Minimo = nullable number, Maximo = nullable number, Medio = nullable number,
            Ultimo = nullable number, Negocios = nullable number, ContratosEmAberto = nullable number,
            VersaoB3 = text
        ]
    )
in
    if Xmls = null then null else Resultado
