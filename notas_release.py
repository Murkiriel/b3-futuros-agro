"""Gera as notas do release do último pregão salvo (usado pelo GitHub Actions).

Uso:
    python notas_release.py notas.md

Escreve as notas em Markdown no arquivo indicado e imprime, em linhas `chave=valor`,
a tag e o título do release (formato aceito por $GITHUB_OUTPUT).
"""

from __future__ import annotations

import csv
import json
import sys
from pathlib import Path

BASE = Path(__file__).resolve().parent
ARQ_CSV = BASE / 'dados' / 'b3_futuros_agro.csv'
ARQ_CONTROLE = BASE / 'dados' / 'controle.json'


def br(valor: str, casas: int = 2) -> str:
    """Número no formato brasileiro (1.234,56); vazio vira travessão."""
    if valor in (None, ''):
        return '–'
    texto = f'{float(valor):,.{casas}f}'
    return texto.replace(',', '_').replace('.', ',').replace('_', '.')


def data_br(iso: str) -> str:
    ano, mes, dia = iso[:10].split('-')
    return f'{dia}/{mes}/{ano}'


def main() -> int:
    destino = Path(sys.argv[1])
    with open(ARQ_CSV, newline='', encoding='utf-8') as f:
        linhas = list(csv.DictReader(f))
    if not linhas:
        raise SystemExit('CSV consolidado vazio')
    controle = json.loads(ARQ_CONTROLE.read_text(encoding='utf-8'))

    ultimo = max(l['Data'] for l in linhas)
    do_dia = [l for l in linhas if l['Data'] == ultimo]
    reg = controle.get(ultimo, {})
    situacao = 'final' if reg.get('final') else 'provisória (será confirmada na próxima execução)'
    datas = sorted({l['Data'] for l in linhas})
    por_contrato: dict[str, list[dict]] = {}
    for l in do_dia:
        por_contrato.setdefault(l['Contrato'], []).append(l)

    partes = [
        f'## Pregão de {data_br(ultimo)}',
        '',
        f'- **Versão do boletim B3:** {do_dia[0]["Versão B3"]} ({situacao})',
        f'- **Dólar B3:** {br(do_dia[0]["Dólar B3"], 4)} · **PTAX:** {br(do_dia[0]["Dólar PTAX"], 4)}',
        '- **Vencimentos:** ' + ', '.join(f'{c} {len(v)}' for c, v in sorted(por_contrato.items())),
        '',
        '### Vencimento mais próximo',
        '',
        '| Contrato | Ticker | Ajuste | Variação | R$ por contrato | Último | Contratos em aberto |',
        '|---|---|---:|---:|---:|---:|---:|',
    ]
    for contrato, itens in sorted(por_contrato.items()):
        # Primeiro vencimento a partir do mês do pregão que tenha ajuste publicado
        candidatos = [l for l in itens if l['Vencimento'][:7] >= ultimo[:7] and l['Ajuste (R$)']]
        l = min(candidatos or itens, key=lambda x: x['Vencimento'])
        moeda = 'R$' if l['Moeda Original'] == 'BRL' else 'US$'
        casas = 4 if contrato == 'SJC' else 2
        partes.append(
            f'| {contrato} – {l["Descrição"]} | {l["Ticker"]} '
            f'| {moeda} {br(l[f"Ajuste ({moeda})"], casas)} '
            f'| {br(l[f"Variação ({moeda})"], casas)} '
            f'| {br(l["R$ por Contrato"])} '
            f'| {br(l[f"Último ({moeda})"], casas)} '
            f'| {br(l["Contratos em Aberto"], 0)} |'
        )
    partes += [
        '',
        '### Arquivos',
        '',
        '- `b3_futuros_agro.xlsx`: planilha formatada, com uma aba que explica cada coluna',
        f'- `b3_futuros_agro.csv`: histórico completo de {data_br(datas[0])} a {data_br(datas[-1])} '
        f'({len(datas)} pregões, {len(linhas)} linhas)',
        '',
        'Fonte: Boletim de Preços da B3 (BVBG.086) e PTAX do Banco Central (SGS 1).',
    ]
    destino.write_text('\n'.join(partes) + '\n', encoding='utf-8')
    print(f'tag=pregao-{ultimo}')
    print(f'titulo=Pregão {data_br(ultimo)}')
    return 0


if __name__ == '__main__':
    sys.exit(main())
