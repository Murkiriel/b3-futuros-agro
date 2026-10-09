// Futuros agro da B3 (BGI, CCM, SJC) - consulta única do Power Query / Power BI
//
// Baixa direto da B3 o boletim simplificado de cada pregão (SPRDaammdd.zip / BVBG.187)
// e a PTAX venda do Banco Central (série SGS 1). Devolve um registro por pregão e
// vencimento, com os preços em R$ e em US$. Não depende de Python.
//
// Como usar: Power BI Desktop > Transformar dados > Nova Fonte > Consulta Nula >
// Editor Avançado > cole este arquivo inteiro > Concluído. Credenciais: Anônimo.
// Privacidade das duas fontes: Público. No Power BI Service, marque "Ignorar conexão
// de teste" nas duas fontes.
//
// Se algum pregão não puder ser lido depois de 6 tentativas, a atualização falha com
// uma mensagem indicando o dia. O Power BI mantém os dados da última atualização boa.
let
    // ============================ CONFIGURAÇÃO ============================

    // Primeiro pregão buscado. Cada atualização baixa de novo todos os dias desde
    // esta data (~150 KB por dia).
    DataInicial = #date(2026, 10, 1),

    // Contratos e tamanho de cada um (unidades por contrato, usado no valor por contrato).
    Contratos = #table(
        type table [Contrato = text, Descrição = text, Unidade = text, Tamanho = number],
        {
            {"BGI", "Boi gordo", "@ (arroba)", 330},
            {"CCM", "Milho", "saca 60 kg", 450},
            {"SJC", "Soja cross (Chicago)", "saca 60 kg", 450}
        }
    ),

    // ======================================================================

    Hoje = Date.From(DateTimeZone.SwitchZone(DateTimeZone.UtcNow(), -3)),
    MaxTentativas = 6,

    // ---------------------------------------------------------------- ZIP
    // Os ZIPs da B3 gravam os tamanhos depois dos dados ("data descriptor"); por isso
    // a leitura parte do diretório central. Devolve uma tabela [Nome, Conteudo].
    DescompactarZip = (Zip as binary) as table =>
        let
            Bytes = Binary.Buffer(Zip),
            Tamanho = Binary.Length(Bytes),
            U16 = (pos as number) as number =>
                let b = Binary.ToList(Binary.Range(Bytes, pos, 2)) in b{0} + b{1} * 256,
            U32 = (pos as number) as number =>
                let b = Binary.ToList(Binary.Range(Bytes, pos, 4)) in b{0} + b{1} * 256 + b{2} * 65536 + b{3} * 16777216,
            InicioBusca = Number.Max({0, Tamanho - 65557}),
            Cauda = List.Buffer(Binary.ToList(Binary.Range(Bytes, InicioBusca))),
            FimDiretorio =
                if Tamanho >= 22 and U32(Tamanho - 22) = 101010256 then
                    Tamanho - 22
                else
                    let
                        Achados = List.Select(
                            List.Reverse({0 .. List.Count(Cauda) - 22}),
                            each Cauda{_} = 80 and Cauda{_ + 1} = 75 and Cauda{_ + 2} = 5 and Cauda{_ + 3} = 6
                        )
                    in
                        if List.IsEmpty(Achados) then error "Arquivo não é um ZIP válido" else InicioBusca + Achados{0},
            QtdArquivos = U16(FimDiretorio + 10),
            InicioDiretorio = U32(FimDiretorio + 16),
            Entradas = List.Generate(
                () => [i = 0, pos = InicioDiretorio],
                each [i] < QtdArquivos,
                each [i = [i] + 1, pos = [pos] + 46 + U16([pos] + 28) + U16([pos] + 30) + U16([pos] + 32)],
                each
                    let
                        p = if U32([pos]) <> 33639248 then error "Diretório central do ZIP corrompido" else [pos],
                        Metodo = U16(p + 10),
                        Local = U32(p + 42),
                        Dados = Binary.Range(Bytes, Local + 30 + U16(Local + 26) + U16(Local + 28), U32(p + 20)),
                        Conteudo =
                            if Metodo = 8 then Binary.Decompress(Dados, Compression.Deflate)
                            else if Metodo = 0 then Dados
                            else error "Método de compressão não suportado: " & Text.From(Metodo)
                    in
                        [Nome = Text.FromBinary(Binary.Range(Bytes, p + 46, U16(p + 28)), TextEncoding.Utf8), Conteudo = Conteudo]
            )
        in
            Table.FromRecords(Entradas, type table [Nome = text, Conteudo = binary]),

    // ---------------------------------------------------------------- boletim de um dia
    // Devolve os vencimentos do dia, ou null se a B3 não tiver boletim (feriado ou
    // ainda não publicado).
    LerBoletim = (Data as date) as nullable table =>
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
                            Table.ToRecords(DescompactarZip(zip)),
                            (r) =>
                                if Text.EndsWith(Text.Lower(r[Nome]), ".zip") then DescompactarZip(r[Conteudo])
                                else Table.FromRecords({r}, type table [Nome = text, Conteudo = binary])
                        )
                    ),
                    Xmls = Table.SelectRows(Arquivos, each Text.EndsWith(Text.Lower([Nome]), ".xml")),
                    Carregados = Table.Buffer(Table.TransformColumns(Xmls, {"Conteudo", Binary.Buffer}))
                in
                    if Table.IsEmpty(Carregados) then error "ZIP da B3 sem XML" else Carregados,
            // A B3 devolve, ao acaso, cerca de 1 em cada 4 pedidos com o ZIP vazio (mesmo em
            // dia com pregão), às vezes o entrega corrompido e às vezes não responde. Nos três
            // casos baixa de novo; só ZIP vazio em todas as tentativas vira "sem boletim".
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
                    else error "Boletim da B3 de " & Date.ToText(Data, "dd/MM/yyyy") & " não obtido em "
                        & Text.From(MaxTentativas) & " tentativas: " & Motivo,
            Xmls = Tentar(1),

            // A B3 republica o boletim no mesmo dia; fica a versão gerada por último
            ComVersao = Table.AddColumn(
                Xmls, "VersaoB3",
                each Text.BetweenDelimiters(
                    Text.FromBinary(Binary.Range([Conteudo], 0, 4096), TextEncoding.Utf8), "<CreDtAndTm>", "</CreDtAndTm>"
                ),
                type text
            ),
            Final = Table.Sort(ComVersao, {{"VersaoB3", Order.Descending}, {"Nome", Order.Descending}}){0},

            Folha = (v) => if Value.Is(v, type table) then (if Table.IsEmpty(v) then null else v{0}[Value]) else v,
            Filhos = (no as record, nome as text) as list => Table.ToRecords(Table.SelectRows(no[Value], each [Name] = nome)),
            Texto = (no as record, nome as text) =>
                let f = Filhos(no, nome) in if List.IsEmpty(f) then null else Folha(f{0}[Value]),
            Raiz = Xml.Document(Final[Conteudo]){0},
            Xchg = Filhos(Filhos(Raiz, "BizFileHdr"){0}, "Xchg"){0},
            Precos = List.Transform(Filhos(Xchg, "BizGrp"), each Filhos(Filhos(_, "Document"){0}, "PricRpt"){0}),

            // Só futuros dos contratos escolhidos (ex.: BGIX26) e só linhas da data do pregão
            Codigos = List.Buffer(Contratos[Contrato]),
            Meses = "FGHJKMNQUVXZ",
            DataTexto = Date.ToText(Data, "yyyy-MM-dd"),
            EhFuturo = (t as nullable text) as logical =>
                t <> null
                and Text.Length(t) = 6
                and List.Contains(Codigos, Text.Start(t, 3))
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
                        Atributos[Attributes], each _ <> null and Value.Is(_, type table) and List.Contains(_[Name], "Ccy")
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
                    ]
        in
            if Xmls = null then null else Table.FromRecords(List.Transform(Selecionados, Linha), TipoLinha),

    TipoLinha = type table [
        Data = date, Contrato = text, Ticker = text, Vencimento = date, Moeda = text,
        Ajuste = nullable number, AjusteAnterior = nullable number, Abertura = nullable number,
        Minimo = nullable number, Maximo = nullable number, Medio = nullable number,
        Ultimo = nullable number, Negocios = nullable number, ContratosEmAberto = nullable number,
        VersaoB3 = text
    ],

    // ---------------------------------------------------------------- PTAX
    // Se o Banco Central não responder, as colunas convertidas ficam em branco.
    RespostaPtax = try List.Buffer(
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
    Ptax = Table.FromRecords(
        List.Transform(
            if RespostaPtax[HasError] then {} else RespostaPtax[Value],
            each [
                Data = #date(Number.From(Text.End([data], 4)), Number.From(Text.Middle([data], 3, 2)), Number.From(Text.Start([data], 2))),
                #"Dólar PTAX" = Number.FromText([valor], "en-US")
            ]
        ),
        type table [Data = date, #"Dólar PTAX" = number]
    ),

    // ---------------------------------------------------------------- todos os dias úteis
    Dias = List.Select(
        List.Dates(DataInicial, Duration.Days(Hoje - DataInicial) + 1, #duration(1, 0, 0, 0)),
        each Date.DayOfWeek(_, Day.Monday) < 5
    ),
    Tabelas = List.RemoveNulls(List.Transform(Dias, LerBoletim)),
    Linhas = if List.IsEmpty(Tabelas) then #table(TipoLinha, {}) else Table.Combine(Tabelas),

    // ---------------------------------------------------------------- colunas finais
    ComContrato = Table.ExpandTableColumn(
        Table.NestedJoin(Linhas, "Contrato", Contratos, "Contrato", "Cfg", JoinKind.LeftOuter),
        "Cfg", {"Descrição", "Unidade", "Tamanho"}
    ),
    ComPtax = Table.ExpandTableColumn(
        Table.NestedJoin(ComContrato, "Data", Ptax, "Data", "Ptax", JoinKind.LeftOuter),
        "Ptax", {"Dólar PTAX"}
    ),
    ComVariacao = Table.AddColumn(
        ComPtax, "Variacao",
        each if [Ajuste] = null or [AjusteAnterior] = null then null else Number.Round([Ajuste] - [AjusteAnterior], 6),
        type nullable number
    ),
    // Oscilação como a B3 publica: último / ajuste anterior - 1, truncada em 2 casas (em %)
    ComOscilacao = Table.AddColumn(
        ComVariacao, "Oscilação",
        each
            if [Ultimo] = null or [AjusteAnterior] = null or [AjusteAnterior] = 0 then null
            else
                let x = ([Ultimo] / [AjusteAnterior] - 1) * 100
                in Number.RoundTowardZero(x + (if x < 0 then -1e-9 else 1e-9), 2) / 100,
        Percentage.Type
    ),
    // A B3 cota BGI e CCM em reais e SJC em dólares; a outra moeda sai pela PTAX do dia
    Converter = (linha as record, valor as nullable number, destino as text) as nullable number =>
        if valor = null then null
        else if linha[Moeda] = destino then valor
        else if linha[#"Dólar PTAX"] = null then null
        else if destino = "BRL" then valor * linha[#"Dólar PTAX"]
        else valor / linha[#"Dólar PTAX"],
    Precos = {
        {"Ajuste", "Ajuste"}, {"AjusteAnterior", "Ajuste Anterior"}, {"Variacao", "Variação"},
        {"Abertura", "Abertura"}, {"Minimo", "Mínimo"}, {"Maximo", "Máximo"},
        {"Medio", "Médio"}, {"Ultimo", "Último"}
    },
    ComMoedas = List.Accumulate(
        Precos,
        ComOscilacao,
        (t, p) =>
            Table.AddColumn(
                Table.AddColumn(t, p{1} & " (R$)", (r) => Converter(r, Record.Field(r, p{0}), "BRL"), type nullable number),
                p{1} & " (US$)", (r) => Converter(r, Record.Field(r, p{0}), "USD"), type nullable number
            )
    ),
    // Valor do ajuste por contrato = variação x tamanho do contrato
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
        {{"Moeda", "Moeda Original"}, {"Negocios", "Nº Negócios"}, {"ContratosEmAberto", "Contratos em Aberto"}, {"VersaoB3", "Versão B3"}}
    ),
    Selecionada = Table.SelectColumns(
        Renomeada,
        {
            "Data", "Contrato", "Descrição", "Ticker", "Vencimento", "Unidade", "Moeda Original", "Dólar PTAX",
            "Ajuste (R$)", "Ajuste (US$)", "Ajuste Anterior (R$)", "Ajuste Anterior (US$)",
            "Variação (R$)", "Variação (US$)", "R$ por Contrato", "US$ por Contrato",
            "Abertura (R$)", "Abertura (US$)", "Mínimo (R$)", "Mínimo (US$)",
            "Máximo (R$)", "Máximo (US$)", "Médio (R$)", "Médio (US$)",
            "Último (R$)", "Último (US$)", "Oscilação", "Nº Negócios", "Contratos em Aberto", "Versão B3"
        }
    ),
    Ordenada = Table.Sort(Selecionada, {{"Data", Order.Ascending}, {"Contrato", Order.Ascending}, {"Vencimento", Order.Ascending}}),
    Resultado = Table.TransformColumnTypes(
        Ordenada,
        {{"Nº Negócios", Int64.Type}, {"Contratos em Aberto", Int64.Type}, {"Oscilação", Percentage.Type}},
        "en-US"
    )
in
    Resultado
