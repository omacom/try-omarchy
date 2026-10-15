"""Plan Japanese input changes in the desktop user's recoverable transaction."""
import base64
import configparser
import io
import os

INPUT = '.config/hypr/input.lua'  # Revision 1 journals can still contain this path.
PROFILE = '.config/fcitx5/profile'
CONFIG = '.config/fcitx5/config'
TARGETS = {INPUT, PROFILE, CONFIG}


def parse(data):
    parser = configparser.ConfigParser(interpolation=None, strict=True)
    parser.optionxform = str
    parser.read_string(data.decode())
    if parser.defaults():
        raise ValueError('Custom Fcitx defaults')
    return {section: dict(parser[section]) for section in parser.sections()}


def profile_update(data, payload, japanese):
    """Recognize historical seeds and their Fcitx-saved forms, not arbitrary INI."""
    existing = parse(data)
    # Current factories seed the owner's Japanese layout before first login.
    initialized = parse((payload / 'fcitx5-profile.ini').read_bytes())
    initialized['Groups/0'].update({'Default Layout': 'jp', 'DefaultIM': 'mozc'})
    initialized['Groups/0/Items/0']['Name'] = 'keyboard-jp'
    initialized['Groups/0/Items/1']['Name'] = 'mozc'
    initialized['Groups/0/Items/2']['Name'] = 'chewing'
    if existing == initialized:
        return data
    for name in ('profile-chewing.ini', 'profile-korean.ini', 'fcitx5-profile.ini'):
        stock = parse((payload / name).read_bytes())
        # Fcitx saves the actual conversion engine as DefaultIM on first use.
        for engine in ('keyboard-us', 'chewing', 'mozc'):
            candidate = {k: dict(v) for k, v in stock.items()}
            candidate['Groups/0']['DefaultIM'] = engine
            for korean_first in (False, True):
                if korean_first and 'Groups/1' not in candidate:
                    continue
                if korean_first:
                    candidate['GroupOrder'] = {'0': 'Korean', '1': 'Default'}
                # Never change which group the owner selected.
                prefer = japanese and candidate['GroupOrder']['0'] == 'Default'
                methods = ('mozc', 'chewing') if prefer else ('chewing', 'mozc')
                updated = {k: dict(v) for k, v in candidate.items()}
                updated['Groups/0/Items/1'] = {'Name': methods[0], 'Layout': ''}
                updated['Groups/0/Items/2'] = {'Name': methods[1], 'Layout': ''}
                if prefer:
                    updated['Groups/0']['DefaultIM'] = 'mozc'
                if updated == existing:
                    return data
                if existing != candidate:
                    continue
                parser = configparser.ConfigParser(interpolation=None)
                parser.optionxform = str
                parser.read_dict(updated)
                output = io.StringIO()
                parser.write(output, space_around_delimiters=False)
                return output.getvalue().encode()
    raise ValueError('Personal Fcitx profile')


def plan(fixes, payload, home, uid, cmdline, language):
    changes = []
    preserved = False
    jis = 'tryomarchy.keyboard=jis' in cmdline.split()

    def add(relative, before, data):
        after = fixes.replacement(data, uid, before['gid'] if before else os.getgid())
        after['mode'] = before['mode'] if before else 0o600
        if before != after:
            changes.append({'path': relative, 'before': before, 'after': after})

    try:
        before = fixes.snapshot(home / PROFILE, home, uid)
        if before:
            add(PROFILE, before, profile_update(base64.b64decode(before['data']), payload,
                                              jis or language.startswith('ja')))
        else:
            preserved = True
    except (OSError, RuntimeError, ValueError, configparser.Error):
        preserved = True
    if jis:
        try:
            before = fixes.snapshot(home / CONFIG, home, uid)
            template = (payload / 'fcitx5-jis-config.ini').read_bytes()
            if before is None:
                add(CONFIG, before, template)
            elif parse(base64.b64decode(before['data'])) != parse(template):
                preserved = True
        except (OSError, RuntimeError, ValueError, configparser.Error):
            preserved = True
    return changes, 'preserved' if preserved else 'pending' if changes else 'current'
