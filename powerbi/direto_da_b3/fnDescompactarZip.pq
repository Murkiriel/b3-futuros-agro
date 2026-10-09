// Abre um arquivo ZIP e devolve uma tabela [Nome, Conteudo] com cada arquivo dele.
// Lê o diretório central do ZIP: os ZIPs da B3 gravam os tamanhos depois dos dados
// ("data descriptor"), o que quebra as funções que leem só o cabeçalho local.
(Zip as binary) as table =>
let
    Bytes = Binary.Buffer(Zip),
    Tamanho = Binary.Length(Bytes),
    U16 = (pos as number) as number =>
        let b = Binary.ToList(Binary.Range(Bytes, pos, 2)) in b{0} + b{1} * 256,
    U32 = (pos as number) as number =>
        let b = Binary.ToList(Binary.Range(Bytes, pos, 4)) in b{0} + b{1} * 256 + b{2} * 65536 + b{3} * 16777216,

    // Registro de fim do diretório central (assinatura 0x06054b50): normalmente nos
    // últimos 22 bytes; se o ZIP tiver comentário, procura do fim para o começo.
    AssinaturaFim = 101010256,
    InicioBusca = Number.Max({0, Tamanho - 65557}),
    Cauda = List.Buffer(Binary.ToList(Binary.Range(Bytes, InicioBusca))),
    FimDiretorio =
        if Tamanho >= 22 and U32(Tamanho - 22) = AssinaturaFim then
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
                p = [pos],
                Valida = if U32(p) <> 33639248 then error "Diretório central do ZIP corrompido" else p,
                Metodo = U16(Valida + 10),
                TamCompactado = U32(p + 20),
                Nome = Text.FromBinary(Binary.Range(Bytes, p + 46, U16(p + 28)), TextEncoding.Utf8),
                Local = U32(p + 42),
                InicioDados = Local + 30 + U16(Local + 26) + U16(Local + 28),
                Dados = Binary.Range(Bytes, InicioDados, TamCompactado),
                Conteudo =
                    if Metodo = 8 then Binary.Decompress(Dados, Compression.Deflate)
                    else if Metodo = 0 then Dados
                    else error "Método de compressão não suportado: " & Text.From(Metodo)
            in
                [Nome = Nome, Conteudo = Conteudo]
    )
in
    Table.FromRecords(Entradas, type table [Nome = text, Conteudo = binary])
