# Futuros agro da B3: BGI, CCM e SJC

Dados diários dos contratos futuros de **boi gordo (BGI)**, **milho (CCM)** e **soja
cross (SJC)** da B3, extraídos do Boletim de Preços oficial e atualizados todo dia útil
por GitHub Actions.

**Baixar:** cada pregão vira um [release](../../releases) com a planilha formatada e o
CSV do histórico completo. Links fixos para o pregão mais recente:

- Planilha: [`b3_futuros_agro.xlsx`](../../releases/latest/download/b3_futuros_agro.xlsx)
- CSV: [`b3_futuros_agro.csv`](../../releases/latest/download/b3_futuros_agro.csv)

O CSV também fica no repositório, em [`dados/b3_futuros_agro.csv`](dados/b3_futuros_agro.csv).
É esse endereço que o Power BI usa:

```
https://raw.githubusercontent.com/Murkiriel/b3-futuros-agro/main/dados/b3_futuros_agro.csv
```

Uma linha por pregão e vencimento, desde 01/10/2026, com:

- **Ajustes:** ajuste, ajuste anterior, variação, valor do ajuste por contrato
- **Preços:** abertura, mínimo, máximo, médio, último, melhor compra e melhor venda
- **Negociação:** oscilação, nº de negócios, contratos negociados, volume em R$ e US$,
  contratos em aberto
- **Câmbio:** Dólar B3 (taxa usada pela própria B3 no boletim) e Dólar PTAX (Banco Central)

Todos os preços aparecem **em R$ e em US$**. A B3 cota BGI e CCM em reais e SJC em
dólares; a outra moeda é calculada com o Dólar B3 do dia.

Formato do CSV: UTF-8, separador vírgula, ponto decimal, datas `AAAA-MM-DD`.

## Usar no Power BI

Cole [`powerbi/FuturosAgro_GitHub.pq`](powerbi/FuturosAgro_GitHub.pq) em
**Transformar dados → Nova Fonte → Consulta Nula → Editor Avançado**. A credencial é
**Anônimo** e a privacidade, **Público**. Para a atualização agendada no Power BI
Service não é preciso gateway.

Em [`powerbi/direto_da_b3/`](powerbi/direto_da_b3/) há uma alternativa em que o próprio
Power BI baixa o boletim simplificado da B3, sem depender deste repositório. Ela traz
menos colunas; veja o `COMO_USAR_POWER_BI.md` de lá.

## Como funciona

- O GitHub Actions ([`.github/workflows/atualizar.yml`](.github/workflows/atualizar.yml))
  roda `b3_futuros_agro.py` às **21h30** (pregão do dia) e às **08h** (confirmação da
  versão final), horário de Brasília, de segunda a sexta.
- O script baixa `PRaammdd.zip` (BVBG.086) em
  `https://www.b3.com.br/pesquisapregao/download` e usa a última versão publicada no
  dia. A B3 republica o boletim algumas vezes durante a noite.
- Cada pregão fica em `dados/diario/AAAA-MM-DD.csv`. O CSV consolidado é refeito a partir
  deles. `dados/controle.json` registra a versão usada em cada dia.
- Quando entra um pregão novo, a automação publica o release `pregao-AAAA-MM-DD`. Na
  rodada da manhã seguinte, os arquivos dele são atualizados para a versão final.
- Sobre a fonte:
  - A B3 às vezes devolve o arquivo vazio, ou corrompido, mesmo em dia de pregão. O
    script tenta de novo antes de concluir que não houve pregão.
  - Dias com erro são tentados de novo na execução seguinte.

## Rodar no próprio computador

Requer Python 3.10+:

```
pip install -r requirements.txt
python b3_futuros_agro.py
```

Além do CSV, gera `b3_futuros_agro.xlsx`, uma planilha formatada com uma aba que explica
cada coluna. Opções: `--inicio AAAA-MM-DD`, `--fim AAAA-MM-DD`, `--contratos BGI CCM SJC`,
`--refazer`, `--sem-excel`. No Windows, `rodar.bat` usa `C:\Python\python.exe`; ajuste o
caminho se o seu Python estiver em outro lugar.

## Observações

- **R$ por contrato:** no SJC, a B3 marca o campo como USD, mas o valor está em reais
  (variação × 450 sacas × Dólar B3).
- **Tamanho dos contratos:** BGI 330 arrobas, CCM 450 sacas, SJC 450 sacas.
- **Fonte:** dados públicos da B3 e do Banco Central do Brasil (série SGS 1). Este
  repositório não tem relação com a B3. Os termos da B3 para uso e redistribuição dos
  dados são dela; confira antes de uso comercial.
