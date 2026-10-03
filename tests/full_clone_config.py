"""Config contract: python tests/full_clone_config.py (no runtime writes)."""
from pathlib import Path

config = (Path(__file__).resolve().parents[1] / 'config.default').read_text(encoding='utf-8')
for block in ('Z2R_AUTO_STANDARD_4', 'Z2R_AUTO_4'):
    text = config.split('#' + block + '_BEGIN', 1)[1].split('#' + block + '_END', 1)[0]
    strategy = next(line for line in text.splitlines() if line.startswith('--lua-desync=') and ':strategy=4 ' in line)
    assert '--lua-desync=multidisorder:blob=' in strategy, (block, 'fake must be sent tail first')
    assert ':pos=2,600,1200:nodrop:strategy=4 ' in strategy, (block, 'full clone segmentation missing')
    assert '--lua-desync=fakeddisorder:pos=sniext+4:tcp_ts=-1000:strategy=4' in strategy
assert '--lua-desync=multidisorder:blob=clone_hcaptcha:tcp_ts=-1000:pos=2,600,1200:nodrop:strategy=36' in config
print('full clone config smoke ok')
