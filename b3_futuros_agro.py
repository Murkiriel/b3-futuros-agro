"""Futuros agro da B3 (BGI, CCM, SJC) a partir do Boletim de Preços oficial.

Baixa o arquivo PRaammdd.zip (BVBG.086) publicado pela B3 em
https://www.b3.com.br/pesquisapregao/download, escolhe a versão final do dia,
extrai ajuste, ajuste anterior, variação, valor por contrato, preços, volume e
contratos em aberto dos futuros escolhidos e acumula tudo num Excel, com os
preços em R$ e em US$ e a cotação do dólar do dia.

Uso:
    python b3_futuros_agro.py                         # de 01/10/2026 até hoje
    python b3_futuros_agro.py --inicio 2026-10-05 --fim 2026-10-08
    python b3_futuros_agro.py --refazer               # baixa de novo dias já salvos
    python b3_futuros_agro.py --contratos BGI CCM     # outros contratos/subconjunto
    python b3_futuros_agro.py --sem-excel             # só o CSV (usado no GitHub Actions)

Arquivos gerados (na pasta deste script):
    b3_futuros_agro.xlsx         planilha consolidada (refeita a cada execução)
    dados/b3_futuros_agro.csv    as mesmas colunas da planilha, em CSV (lido pelo Power BI)
    dados/diario/AAAA-MM-DD.csv  dados brutos de cada pregão (fonte das saídas)
    dados/controle.json          versão B3 usada em cada dia e se ela já é final
    dados/ptax.json              PTAX venda do Banco Central já consultadas

Dólar:
    - "Dólar B3" é a taxa que a própria B3 usou no boletim para converter os
      volumes entre R$ e US$ (a mesma do valor de ajuste por contrato do SJC).
      É ela que converte os preços entre R$ e US$ na planilha.
    - "Dólar PTAX" é a PTAX venda do Banco Central (série SGS 1), só como
      referência. Se o Banco Central não responder, a coluna fica vazia.

Regras:
    - Fins de semana são pulados; feriados são detectados pela B3 devolver o
      arquivo vazio e são apenas reportados (verificá-los de novo custa < 1 s).
    - Um dia baixado no próprio dia do pregão é provisório (a B3 republica o
      boletim até ~20h30) e é baixado de novo na execução seguinte. Depois disso
      fica marcado como final e não é baixado mais.
    - Só entram linhas cuja data é a do pregão do arquivo; negócios já
      registrados para o pregão seguinte ficam para o arquivo do dia seguinte.

Requer Python 3.10+ com lxml e openpyxl.
"""

from __future__ import annotations

import argparse
import collections
import csv
import datetime as dt
import io
import json
import re
import sys
import time
import urllib.error
import urllib.request
import zipfile
from pathlib import Path

from lxml import etree
from openpyxl import Workbook
from openpyxl.styles import Alignment, Font
from openpyxl.utils import get_column_letter
from openpyxl.worksheet.table import Table, TableStyleInfo

BASE = Path(__file__).resolve().parent
DIR_DIARIO = BASE / 'dados' / 'diario'
ARQ_CONTROLE = BASE / 'dados' / 'controle.json'
ARQ_PTAX = BASE / 'dados' / 'ptax.json'
ARQ_EXCEL = BASE / 'b3_futuros_agro.xlsx'
ARQ_CSV = BASE / 'dados' / 'b3_futuros_agro.csv'

# A B3 e o "dia do pregão" seguem o horário de Brasília (sem horário de verão desde
# 2019); servidores como o do GitHub Actions rodam em UTC.
FUSO_BRASILIA = dt.timezone(dt.timedelta(hours=-3))


def agora() -> dt.datetime:
    return dt.datetime.now(FUSO_BRASILIA)


def hoje() -> dt.date:
    return agora().date()

URL_PR = 'https://www.b3.com.br/pesquisapregao/download?filelist=PR{:%y%m%d}.zip'
URL_PTAX = ('https://api.bcb.gov.br/dados/serie/bcdata.sgs.1/dados'
            '?formato=json&dataInicial={:%d/%m/%Y}&dataFinal={:%d/%m/%Y}')
USER_AGENT = ('Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
              '(KHTML, like Gecko) Chrome/125.0.0.0 Safari/537.36')
INICIO_PADRAO = dt.date(2026, 10, 1)
CONTRATOS_PADRAO = ['BGI', 'CCM', 'SJC']

# Tamanho mínimo de um boletim real; em feriado ou antes da publicação a B3
# devolve um ZIP vazio de poucos bytes.
TAMANHO_MINIMO_ZIP = 100_000
TENTATIVAS = 4
ESPERA_INICIAL_S = 5
# Tentativas quando a B3 devolve o ZIP vazio ou corrompido (ver baixar_boletim).
TENTATIVAS_VAZIO = 6
# Só instrumentos com volume relevante entram na estimativa da taxa da B3,
# para o arredondamento dos volumes não distorcer a razão R$/US$.
VOLUME_MINIMO_USD_TAXA = 100_000

NS = '{urn:bvmf.217.01.xsd}'
MESES_VENC = dict(zip('FGHJKMNQUVXZ', range(1, 13)))

DESCRICAO = {
    'BGI': ('Boi gordo', '@ (arroba)'),
    'CCM': ('Milho', 'saca 60 kg'),
    'SJC': ('Soja cross (Chicago)', 'saca 60 kg'),
}

# Campos do XML guardados nos CSVs diários.
TAGS_XML = ['AdjstdQt', 'PrvsAdjstdQt', 'VartnPts', 'AdjstdValCtrct',
            'FrstPric', 'MinPric', 'MaxPric', 'TradAvrgPric', 'LastPric', 'OscnPctg',
            'BestBidPric', 'BestAskPric', 'TradQty', 'FinInstrmQty',
            'NtlFinVol', 'IntlFinVol', 'OpnIntrst']
CAMPOS_CSV = ['data', 'contrato', 'descricao', 'ticker', 'vencimento', 'unidade',
              'moeda', 'dolar_b3', 'versao_b3'] + TAGS_XML

# Preços cotados na moeda do contrato (BRL ou USD) que a planilha mostra nas duas.
PRECOS = [
    ('Ajuste', 'AdjstdQt', 'Preço de ajuste do dia'),
    ('Ajuste Anterior', 'PrvsAdjstdQt', 'Preço de ajuste do pregão anterior'),
    ('Variação', 'VartnPts', 'Ajuste - ajuste anterior'),
    ('Abertura', 'FrstPric', 'Primeiro preço negociado'),
    ('Mínimo', 'MinPric', 'Menor preço negociado'),
    ('Máximo', 'MaxPric', 'Maior preço negociado'),
    ('Médio', 'TradAvrgPric', 'Preço médio ponderado'),
    ('Último', 'LastPric', 'Último preço negociado'),
    ('Melhor Compra', 'BestBidPric', 'Melhor oferta de compra no fechamento'),
    ('Melhor Venda', 'BestAskPric', 'Melhor oferta de venda no fechamento'),
]

INT, DEC, PRC, PCT, TXT, DATA, FX = (
    '#,##0', '#,##0.00', '#,##0.00######', '0.00%', '@', 'dd/mm/yyyy', '0.0000')


def _colunas_excel():
    """(cabeçalho, função linha->valor, formato, descrição) de cada coluna."""
    def campo(nome, tipo=float):
        return lambda r: _num(r.get(nome), tipo)

    def em(moeda, tag):
        return lambda r: _converter_moeda(r, tag, moeda)

    cols = [
        ('Data', lambda r: _data(r['data']), DATA, 'Data do pregão'),
        ('Contrato', lambda r: r['contrato'], TXT, 'Código do contrato'),
        ('Descrição', lambda r: r['descricao'], TXT, 'Nome do contrato'),
        ('Ticker', lambda r: r['ticker'], TXT, 'Código de negociação do vencimento'),
        ('Vencimento', lambda r: _data(r['vencimento']), 'mmm/yy', 'Mês/ano de vencimento'),
        ('Unidade', lambda r: r['unidade'], TXT, 'Quantidade a que os preços se referem'),
        ('Moeda Original', lambda r: r['moeda'], TXT,
         'Moeda em que a B3 cota o contrato (BRL ou USD); a outra moeda é convertida pelo Dólar B3'),
        ('Dólar B3', campo('dolar_b3'), FX,
         'Taxa R$/US$ usada pela B3 no boletim do dia (razão entre volume em R$ e em US$)'),
        ('Dólar PTAX', lambda r: r.get('ptax'), FX,
         'PTAX venda do Banco Central no dia (SGS 1), apenas referência'),
    ]
    for cab, tag, desc in PRECOS[:3]:
        cols += [(f'{cab} (R$)', em('BRL', tag), PRC, f'{desc}, em reais'),
                 (f'{cab} (US$)', em('USD', tag), PRC, f'{desc}, em dólares')]
    cols += [
        ('R$ por Contrato', campo('AdjstdValCtrct'), DEC,
         'Valor do ajuste por contrato em reais, como liquidado pela B3. No SJC a B3 marca o campo '
         'como USD, mas o valor é variação x 450 sacas x Dólar B3, ou seja, está em reais'),
        ('US$ por Contrato', lambda r: _div(_num(r.get('AdjstdValCtrct')), _num(r.get('dolar_b3'))),
         DEC, 'R$ por Contrato / Dólar B3'),
    ]
    for cab, tag, desc in PRECOS[3:8]:
        cols += [(f'{cab} (R$)', em('BRL', tag), PRC, f'{desc}, em reais'),
                 (f'{cab} (US$)', em('USD', tag), PRC, f'{desc}, em dólares')]
    cols.append(('Oscilação', lambda r: _div(_num(r.get('OscnPctg')), 100), PCT,
                 'Oscilação do dia informada pela B3'))
    for cab, tag, desc in PRECOS[8:]:
        cols += [(f'{cab} (R$)', em('BRL', tag), PRC, f'{desc}, em reais'),
                 (f'{cab} (US$)', em('USD', tag), PRC, f'{desc}, em dólares')]
    cols += [
        ('Nº Negócios', campo('TradQty', int), INT, 'Quantidade de negócios'),
        ('Contratos Negociados', campo('FinInstrmQty', int), INT, 'Quantidade de contratos negociados'),
        ('Volume (R$)', campo('NtlFinVol'), DEC, 'Volume financeiro em reais (B3)'),
        ('Volume (US$)', campo('IntlFinVol'), DEC, 'Volume financeiro em dólares (B3)'),
        ('Contratos em Aberto', campo('OpnIntrst', int), INT, 'Posição em aberto'),
        ('Versão B3', lambda r: r['versao_b3'], TXT, 'Data/hora de geração do boletim usado'),
    ]
    return cols


class SemBoletim(Exception):
    """A B3 não tem boletim para a data (feriado ou ainda não publicado)."""


def log(msg: str) -> None:
    print(f'[{agora():%H:%M:%S}] {msg}', flush=True)


# --------------------------------------------------------------------------- conversões

def _num(valor, tipo=float):
    if valor in (None, ''):
        return None
    return int(float(valor)) if tipo is int else float(valor)


def _data(valor: str | None):
    return dt.datetime.strptime(valor, '%Y-%m-%d') if valor else None


def _div(a, b):
    return round(a / b, 6) if a is not None and b else None


def _converter_moeda(r: dict, tag: str, destino: str):
    valor, taxa = _num(r.get(tag)), _num(r.get('dolar_b3'))
    if valor is None:
        return None
    if r['moeda'] == destino:
        return valor
    if not taxa:
        return None
    return round(valor * taxa if destino == 'BRL' else valor / taxa, 6)


# --------------------------------------------------------------------------- download

def baixar(url: str, timeout: int = 180) -> bytes:
    req = urllib.request.Request(url, headers={'User-Agent': USER_AGENT, 'Accept': '*/*'})
    for tentativa in range(1, TENTATIVAS + 1):
        try:
            with urllib.request.urlopen(req, timeout=timeout) as resp:
                return resp.read()
        except urllib.error.HTTPError as e:
            if e.code not in (429, 500, 502, 503, 504) or tentativa == TENTATIVAS:
                raise
            erro = f'HTTP {e.code}'
        except (urllib.error.URLError, TimeoutError, ConnectionError) as e:
            if tentativa == TENTATIVAS:
                raise
            erro = str(getattr(e, 'reason', e))
        espera = ESPERA_INICIAL_S * 3 ** (tentativa - 1)
        log(f'  falha ao baixar ({erro}); nova tentativa em {espera}s')
        time.sleep(espera)
    raise RuntimeError('inalcançável')


def baixar_boletim(dia: dt.date) -> bytes:
    # A B3 devolve, ao acaso, cerca de 1 em cada 4 pedidos com o ZIP vazio mesmo em
    # dia com pregão, e às vezes entrega o ZIP corrompido com HTTP 200. Nos dois
    # casos baixa de novo; só depois de todas as tentativas vazias o dia é tratado
    # como sem boletim (feriado ou ainda não publicado).
    for tentativa in range(1, TENTATIVAS_VAZIO + 1):
        try:
            conteudo = baixar(URL_PR.format(dia))
        except urllib.error.HTTPError as e:
            if e.code == 404:
                raise SemBoletim('HTTP 404') from e
            raise
        if len(conteudo) < TAMANHO_MINIMO_ZIP:
            erro = f'arquivo vazio ({len(conteudo)} bytes)'
            if tentativa == TENTATIVAS_VAZIO:
                raise SemBoletim(f'{erro} em {TENTATIVAS_VAZIO} tentativas')
        else:
            try:
                with zipfile.ZipFile(io.BytesIO(conteudo)) as zf:
                    if zf.testzip() is None:
                        return conteudo
                erro = 'ZIP com arquivo corrompido'
            except zipfile.BadZipFile:
                erro = f'ZIP inválido ({len(conteudo)} bytes)'
            if tentativa == TENTATIVAS_VAZIO:
                raise zipfile.BadZipFile(f'{erro} após {TENTATIVAS_VAZIO} tentativas')
        espera = 2 * tentativa
        log(f'  {dia:%d/%m}: {erro}; nova tentativa em {espera}s')
        time.sleep(espera)
    raise RuntimeError('inalcançável')


def atualizar_ptax(inicio: dt.date, fim: dt.date) -> dict[str, float]:
    """PTAX venda por data ISO. Usa o que já foi salvo se o Banco Central falhar."""
    try:
        ptax = json.loads(ARQ_PTAX.read_text(encoding='utf-8'))
    except (FileNotFoundError, json.JSONDecodeError):
        ptax = {}
    try:
        for item in json.loads(baixar(URL_PTAX.format(inicio, fim), timeout=60)):
            ptax[dt.datetime.strptime(item['data'], '%d/%m/%Y').date().isoformat()] = float(item['valor'])
        _gravar_json(ARQ_PTAX, ptax)
    except Exception as e:
        log(f'AVISO: PTAX do Banco Central indisponível ({type(e).__name__}: {e}); '
            'coluna Dólar PTAX pode ficar incompleta')
    return ptax


# --------------------------------------------------------------------------- leitura

def _xmls_do_zip(zf: zipfile.ZipFile):
    """Devolve (ZipFile, nome) de cada XML, abrindo ZIPs aninhados."""
    for nome in zf.namelist():
        if nome.lower().endswith('.xml'):
            yield zf, nome
        elif nome.lower().endswith('.zip'):
            yield from _xmls_do_zip(zipfile.ZipFile(io.BytesIO(zf.read(nome))))


def _data_geracao(zf: zipfile.ZipFile, nome: str) -> str:
    with zf.open(nome) as f:
        cabecalho = f.read(8192).decode('utf-8', errors='ignore')
    m = re.search(r'<CreDtAndTm>([^<]+)</CreDtAndTm>', cabecalho)
    return m.group(1) if m else ''


def escolher_versao_final(conteudo: bytes) -> tuple[zipfile.ZipFile, str, str]:
    """A B3 republica o boletim várias vezes no mesmo dia; cada XML é uma versão
    completa. Fica a de geração mais recente (desempate pelo nome)."""
    candidatos = [(_data_geracao(zf, nome), nome, zf)
                  for zf, nome in _xmls_do_zip(zipfile.ZipFile(io.BytesIO(conteudo)))]
    if not candidatos:
        raise ValueError('nenhum XML dentro do ZIP da B3')
    geracao, nome, zf = max(candidatos, key=lambda c: (c[0], c[1]))
    return zf, nome, geracao


def extrair_linhas(zf: zipfile.ZipFile, nome: str, dia: dt.date,
                   contratos: list[str], geracao: str) -> list[dict]:
    padrao = re.compile(r'^(%s)([FGHJKMNQUVXZ])(\d{2})$' % '|'.join(map(re.escape, contratos)))
    data_pregao = dia.isoformat()
    taxas = collections.Counter()
    linhas = []
    with zf.open(nome) as f:
        for _, el in etree.iterparse(f, tag=NS + 'PricRpt'):
            if el.findtext(f'{NS}TradDt/{NS}Dt') == data_pregao:
                attrs = el.find(NS + 'FinInstrmAttrbts')
                # Taxa R$/US$ da B3: moda da razão entre volumes nos instrumentos negociados.
                if attrs is not None:
                    brl, usd = attrs.findtext(NS + 'NtlFinVol'), attrs.findtext(NS + 'IntlFinVol')
                    if brl and usd and float(usd) >= VOLUME_MINIMO_USD_TAXA:
                        taxas[round(float(brl) / float(usd), 4)] += 1

                ticker = (el.findtext(f'{NS}SctyId/{NS}TckrSymb') or '').strip()
                m = padrao.match(ticker)
                if m and attrs is not None:
                    contrato, letra, ano = m.groups()
                    descricao, unidade = DESCRICAO.get(contrato, ('', ''))
                    linha = {
                        'data': data_pregao,
                        'contrato': contrato,
                        'descricao': descricao,
                        'ticker': ticker,
                        'vencimento': f'20{ano}-{MESES_VENC[letra]:02d}-01',
                        'unidade': unidade,
                        'versao_b3': geracao,
                    }
                    for secao in (el.find(NS + 'TradDtls'), attrs):
                        for c in (secao if secao is not None else []):
                            tag = etree.QName(c).localname
                            if tag in TAGS_XML:
                                linha[tag] = c.text
                            if tag == 'AdjstdQt':
                                linha['moeda'] = c.get('Ccy')
                    linha.setdefault('moeda', _moeda_do_registro(attrs))
                    linhas.append(linha)
            el.clear()
            while el.getprevious() is not None:
                del el.getparent()[0]

    taxa = taxas.most_common(1)[0][0] if taxas else ''
    for linha in linhas:
        linha['dolar_b3'] = taxa
    return linhas


def _moeda_do_registro(attrs) -> str:
    for c in attrs:
        if c.get('Ccy') and etree.QName(c).localname not in (
                'NtlFinVol', 'IntlFinVol', 'NtlRglrVol', 'IntlRglrVol',
                'NtlNonRglrVol', 'IntlNonRglrVol', 'EqvtVal'):
            return c.get('Ccy')
    return 'BRL'


# --------------------------------------------------------------------------- persistência

def _gravar_json(destino: Path, dados: dict) -> None:
    destino.parent.mkdir(parents=True, exist_ok=True)
    tmp = destino.with_suffix('.tmp')
    tmp.write_text(json.dumps(dados, indent=2, sort_keys=True), encoding='utf-8')
    tmp.replace(destino)


def carregar_controle() -> dict:
    try:
        return json.loads(ARQ_CONTROLE.read_text(encoding='utf-8'))
    except (FileNotFoundError, json.JSONDecodeError):
        return {}


def salvar_dia(dia: dt.date, linhas: list[dict]) -> None:
    DIR_DIARIO.mkdir(parents=True, exist_ok=True)
    destino = DIR_DIARIO / f'{dia.isoformat()}.csv'
    tmp = destino.with_suffix('.tmp')
    with open(tmp, 'w', newline='', encoding='utf-8') as f:
        w = csv.DictWriter(f, fieldnames=CAMPOS_CSV)
        w.writeheader()
        w.writerows(linhas)
    tmp.replace(destino)


def ler_todos_os_dias() -> list[dict]:
    linhas = []
    for arq in sorted(DIR_DIARIO.glob('*.csv')):
        with open(arq, newline='', encoding='utf-8') as f:
            linhas.extend(csv.DictReader(f))
    return sorted(linhas, key=lambda r: (r['data'], r['contrato'], r['vencimento']))


# --------------------------------------------------------------------------- CSV consolidado

def gerar_csv(linhas: list[dict]) -> Path:
    """Mesmas colunas da planilha, em CSV (vírgula, ponto decimal, datas AAAA-MM-DD),
    para o Power BI ou outro programa ler direto do GitHub."""
    def texto(valor) -> str:
        if valor is None:
            return ''
        if isinstance(valor, dt.datetime):
            return valor.date().isoformat()
        return repr(valor) if isinstance(valor, float) else str(valor)

    colunas = _colunas_excel()
    ARQ_CSV.parent.mkdir(parents=True, exist_ok=True)
    tmp = ARQ_CSV.with_suffix('.tmp')
    with open(tmp, 'w', newline='', encoding='utf-8') as f:
        w = csv.writer(f)
        w.writerow([c[0] for c in colunas])
        for r in linhas:
            w.writerow([texto(fn(r)) for _, fn, _, _ in colunas])
    tmp.replace(ARQ_CSV)
    return ARQ_CSV


# --------------------------------------------------------------------------- Excel

def gerar_excel(linhas: list[dict]) -> Path:
    contratos = sorted({r['contrato'] for r in linhas})
    colunas = _colunas_excel()
    ultima = get_column_letter(len(colunas))

    wb = Workbook()
    wb._named_styles['Normal'].font = Font(name='Arial', size=10)
    ws = wb.active
    ws.title = 'Futuros Agro'
    ws.append([c[0] for c in colunas])
    for r in linhas:
        ws.append([f(r) for _, f, _, _ in colunas])
    n = max(len(linhas) + 1, 2)
    for j, (cab, _, fmt, _) in enumerate(colunas, 1):
        letra = get_column_letter(j)
        for (cel,) in ws[f'{letra}2:{letra}{n}']:
            cel.number_format = fmt
        ws.column_dimensions[letra].width = max(min(len(cab) + 3, 24), 11)
    ws.column_dimensions['C'].width = 21
    ws.column_dimensions[ultima].width = 20
    for c in ws[1]:
        c.font = Font(name='Arial', size=10, bold=True, color='FFFFFF')
        c.alignment = Alignment(wrap_text=True, vertical='center')
    ws.row_dimensions[1].height = 30
    tabela = Table(displayName='FuturosAgro', ref=f'A1:{ultima}{n}')
    tabela.tableStyleInfo = TableStyleInfo(name='TableStyleMedium2', showRowStripes=True)
    ws.add_table(tabela)
    ws.freeze_panes = 'E2'

    info = wb.create_sheet('Sobre')
    info.column_dimensions['A'].width = 24
    info.column_dimensions['B'].width = 110
    negrito = Font(name='Arial', size=10, bold=True)
    datas = sorted({r['data'] for r in linhas})
    meta = [
        ('Fonte', 'B3 – Boletim de Preços (PRaammdd.zip / BVBG.086), dados públicos; '
                  'PTAX: Banco Central do Brasil (SGS 1)'),
        ('Contratos', ', '.join(f'{c} ({DESCRICAO.get(c, ("?",))[0]})' for c in contratos)),
        ('Período', f'{datas[0]} a {datas[-1]} ({len(datas)} pregões)' if datas else 'sem dados'),
        ('Atualizado em', f'{agora():%d/%m/%Y %H:%M} (horário de Brasília)'),
        ('Como atualizar', 'Rode rodar.bat (ou python b3_futuros_agro.py) após ~21h ou no dia seguinte'),
        ('R$ e US$', 'A B3 cota BGI e CCM em reais e SJC em dólares. A outra moeda é calculada '
                     'com o Dólar B3 do dia (a taxa que a própria B3 usou no boletim)'),
        ('Versão B3', 'A B3 republica o boletim várias vezes no dia; usa-se sempre a versão mais recente'),
        ('Célula vazia', 'Campo não informado pela B3 (ex.: vencimento sem negócios no dia não tem preços)'),
        ('', ''),
        ('Coluna', 'Descrição'),
    ]
    for a, b in meta:
        info.append([a, b])
    for cab, _, _, desc in colunas:
        info.append([cab, desc])
    for r in info.iter_rows(min_row=1, max_row=len(meta)):
        r[0].font = negrito
    for c in info[len(meta)]:
        c.font = negrito

    try:
        wb.save(ARQ_EXCEL)
        return ARQ_EXCEL
    except PermissionError:
        alternativo = ARQ_EXCEL.with_name(f'{ARQ_EXCEL.stem}_{dt.datetime.now():%Y%m%d_%H%M%S}.xlsx')
        wb.save(alternativo)
        log(f'AVISO: {ARQ_EXCEL.name} está aberto no Excel; planilha salva como {alternativo.name}')
        return alternativo


# --------------------------------------------------------------------------- execução

def dias_uteis(inicio: dt.date, fim: dt.date):
    dia = inicio
    while dia <= fim:
        if dia.weekday() < 5:
            yield dia
        dia += dt.timedelta(days=1)


def processar_dia(dia: dt.date, contratos: list[str], controle: dict) -> None:
    t0 = time.time()
    zf, nome, geracao = escolher_versao_final(baixar_boletim(dia))
    linhas = extrair_linhas(zf, nome, dia, contratos, geracao)
    if not linhas:
        raise ValueError(f'boletim sem nenhum dos contratos {contratos} (códigos mudaram?)')
    salvar_dia(dia, linhas)
    final = hoje() > dia
    encontrados = sorted({l['contrato'] for l in linhas})
    controle[dia.isoformat()] = {
        'versao_b3': geracao,
        'arquivo_xml': nome,
        'contratos': encontrados,
        'dolar_b3': linhas[0]['dolar_b3'],
        'final': final,
        'baixado_em': agora().isoformat(timespec='seconds'),
    }
    _gravar_json(ARQ_CONTROLE, controle)
    faltando = sorted(set(contratos) - set(encontrados))
    aviso = f' | AVISO: sem {", ".join(faltando)}' if faltando else ''
    log(f'{dia:%d/%m/%Y}: {len(linhas)} vencimentos, dólar B3 {linhas[0]["dolar_b3"]}, '
        f'versão {geracao}{"" if final else " (provisória)"}, {time.time() - t0:.0f}s{aviso}')


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split('\n\n')[0])
    ap.add_argument('--inicio', type=dt.date.fromisoformat, default=INICIO_PADRAO,
                    help='primeira data (AAAA-MM-DD), padrão %(default)s')
    ap.add_argument('--fim', type=dt.date.fromisoformat, default=hoje(),
                    help='última data (AAAA-MM-DD), padrão hoje')
    ap.add_argument('--contratos', nargs='+', default=CONTRATOS_PADRAO, type=str.upper,
                    help='códigos dos contratos, padrão %(default)s')
    ap.add_argument('--refazer', action='store_true', help='baixa de novo dias já salvos')
    ap.add_argument('--sem-excel', action='store_true',
                    help='não gera a planilha .xlsx (só o CSV consolidado)')
    args = ap.parse_args()

    fim = min(args.fim, hoje())
    controle = carregar_controle()
    erros, sem_boletim, ja_salvos = [], [], 0
    log(f'Contratos {", ".join(args.contratos)} de {args.inicio:%d/%m/%Y} a {fim:%d/%m/%Y}')

    for dia in dias_uteis(args.inicio, fim):
        reg = controle.get(dia.isoformat())
        if (not args.refazer and reg and reg.get('final')
                and set(args.contratos) <= set(reg.get('contratos', []))
                and (DIR_DIARIO / f'{dia.isoformat()}.csv').exists()):
            ja_salvos += 1
            continue
        try:
            processar_dia(dia, args.contratos, controle)
        except SemBoletim as e:
            sem_boletim.append(dia)
            motivo = 'ainda não publicado' if dia == hoje() else 'feriado/sem pregão'
            log(f'{dia:%d/%m/%Y}: sem boletim – {motivo} ({e})')
        except Exception as e:  # um dia com problema não impede os demais
            erros.append(dia)
            log(f'{dia:%d/%m/%Y}: ERRO {type(e).__name__}: {e}')

    # As saídas trazem sempre todo o histórico salvo, qualquer que seja o --inicio
    linhas = ler_todos_os_dias()
    inicio_ptax = min([dt.date.fromisoformat(linhas[0]['data']), args.inicio]) if linhas else args.inicio
    ptax = atualizar_ptax(inicio_ptax, fim)
    for l in linhas:
        l['ptax'] = ptax.get(l['data'])
    log(f'{ja_salvos} dia(s) já estavam salvos; {len(sem_boletim)} sem boletim; {len(erros)} com erro')
    log(f'CSV: {gerar_csv(linhas)} ({len(linhas)} linhas)')
    if not args.sem_excel:
        log(f'Planilha: {gerar_excel(linhas)}')
    if erros:
        log('Dias com erro (serão tentados de novo na próxima execução): '
            + ', '.join(f'{d:%d/%m}' for d in erros))
    return 1 if erros else 0


if __name__ == '__main__':
    sys.exit(main())
