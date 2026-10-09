# Futuros agro da B3 no Power BI (sem Python)

O Power BI baixa direto da B3 o boletim simplificado de cada pregão (`SPRDaammdd.zip`)
e a PTAX do Banco Central. Não depende de Python nem do seu computador ligado.

> Alternativa à consulta `../FuturosAgro_GitHub.pq`, que é mais simples e traz mais
> colunas. Use estas se quiser que o Power BI busque direto na B3. Para uma versão em
> uma consulta só, veja `B3_FuturosAgro_ConsultaUnica.pq`.

## Montar no Power BI Desktop

1. **Página Inicial → Transformar dados**. No Editor do Power Query: **Nova Fonte → Consulta Nula**.
2. **Editor Avançado** → apague o conteúdo → cole o conteúdo do arquivo `.pq` → **Concluído**.
3. Renomeie a consulta com o **nome exato do arquivo** (sem `.pq`).
4. Repita nesta ordem: `DataInicial`, `ConfigContratos`, `fnDescompactarZip`, `fnBoletimSPRD`,
   `PTAX`, `BaseDias`, `StatusDownload`, `FuturosAgro`.
5. Em `DataInicial`, `ConfigContratos`, `fnDescompactarZip`, `fnBoletimSPRD`, `PTAX` e `BaseDias`:
   botão direito → desmarque **Habilitar carga** (são auxiliares).
6. **Fechar e Aplicar**.

## Primeira atualização

- Se pedir **credenciais** para `b3.com.br` ou `api.bcb.gov.br`: escolha **Anônimo**.
- Se pedir **níveis de privacidade**: marque as duas fontes como **Público**.
- A atualização leva cerca de 1 minuto. Dias sem pregão e o dia de hoje antes da publicação
  (~21h) custam ~30 s cada, porque a consulta tenta de novo antes de concluir que não há boletim.

## Publicar e atualizar sozinho (Power BI Service)

1. **Publicar** o relatório.
2. No serviço: modelo semântico → **Configurações → Credenciais da fonte de dados**:
   - `https://www.b3.com.br/...` e `https://api.bcb.gov.br/...`: Anônimo, privacidade
     **Público** e marque **Ignorar conexão de teste** nas duas. Os endereços sem
     parâmetros não respondem dados (B3 devolve vazio, Banco Central devolve erro 406),
     então o teste falharia mesmo com tudo certo.
3. **Atualização agendada**: ligada, fuso **(UTC-03:00) Brasília**, horários sugeridos
   **21:30** e **07:00** (o segundo cobre dias em que a B3 publica mais tarde).
   Não precisa de gateway: as duas fontes são públicas na internet.

## Consultas

| Consulta | Carrega? | O que faz |
|---|---|---|
| `FuturosAgro` | sim | Tabela final, um registro por pregão e vencimento |
| `StatusDownload` | sim | Situação de cada dia: OK, Sem pregão, Ainda não publicado ou Erro |
| `DataInicial` | não | Primeiro pregão buscado (parâmetro; padrão 01/10/2026) |
| `ConfigContratos` | não | Contratos e tamanho de cada um (BGI 330 @, CCM 450 sc, SJC 450 sc) |
| `PTAX` | não | PTAX venda do Banco Central (série SGS 1) |
| `BaseDias` | não | Baixa o boletim de cada dia útil |
| `fnBoletimSPRD` | não | Baixa e lê o boletim de um dia |
| `fnDescompactarZip` | não | Descompacta os ZIPs da B3 |

## Colunas de FuturosAgro

Data, Contrato, Descrição, Ticker, Vencimento, Unidade, Moeda Original, Dólar PTAX e, em
**R$ e US$**: Ajuste, Ajuste Anterior, Variação, Abertura, Mínimo, Máximo, Médio e Último.
Também: R$ por Contrato, US$ por Contrato, Nº Negócios, Contratos em Aberto e Versão B3.

- A B3 cota BGI e CCM em reais e SJC em dólares. A outra moeda é calculada com a **PTAX**
  do dia.
- **R$ por Contrato** = Variação × tamanho do contrato. No BGI e no CCM é exatamente o
  valor da B3. No SJC pode diferir até ~0,3% do valor liquidado pela B3, porque a B3
  converte com uma taxa própria, que não vem no boletim simplificado.
- Se o Banco Central estiver fora do ar, as colunas convertidas ficam em branco. A
  atualização não falha.

## Cuidados

- **Dias com Erro** ficam fora de `FuturosAgro` e aparecem em `StatusDownload`. Vale pôr
  no relatório um cartão com a contagem de `Status = "Erro"`.
- Cada atualização baixa de novo todos os dias desde `DataInicial` (~150 KB por dia).
  Um ano inteiro são ~250 arquivos, alguns minutos de atualização. Se ficar lento,
  avance a `DataInicial`.
- Para acrescentar um contrato (ex.: `SFI`), inclua uma linha em `ConfigContratos` com o
  tamanho do contrato.
