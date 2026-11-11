#!/usr/bin/env python3
"""Build a reversible, local-only PCSD00001 1.03 text/font patch.
Uses the user's own HG2 archive, no game downloads. Original files stay intact.
Requires Pillow >= 11, fontTools and opencc-python-reimplemented.
"""
import argparse, hashlib, io, json, shutil, struct
from pathlib import Path
from PIL import Image, ImageDraw, ImageFont
from fontTools.ttLib import TTFont
from opencc import OpenCC

MAGIC = bytes.fromhex('eaf64788b6fdf49d1c5579f1eb700f98')

def read_length(b, p):
    n = b[p]; p += 1
    if n & 128:
        n = ((n & 127) << 8) | b[p]; p += 1
    return n, p

def write_length(n):
    assert 0 <= n < 32768
    return bytes([n]) if n < 128 else bytes([128 | (n >> 8), n & 255])

def read_tlv(b):
    p = 0; result = []
    while p < len(b):
        tag = b[p]; p += 1
        size, p = read_length(b, p)
        assert p + size <= len(b)
        result.append((tag, b[p:p+size])); p += size
    return result

def write_tlv(rows):
    return b''.join(bytes([t]) + write_length(len(v)) + v for t, v in rows)

def archive_index(path):
    with path.open('rb') as f:
        header = f.read(48); assert header[:4] == b'HG2\0'
        count = struct.unpack_from('<I', header, 32)[0]
        names = struct.unpack_from('<I', header, 44)[0]
        info = f.read(count * 12); f.seek(names); ptrs = f.read(count * 4)
        result = {}
        for i in range(count):
            unknown, size, offset = struct.unpack_from('<III', info, i * 12)
            assert offset + size <= path.stat().st_size
            f.seek(struct.unpack_from('<I', ptrs, i * 4)[0]); name = bytearray()
            while (c := f.read(1)) != b'\0':
                assert c; name += c
            name = name.decode('utf8'); assert name not in result
            result[name] = dict(index=i, size=size, offset=offset, unknown=unknown)
        return result

def spread(v):
    v = (v | (v << 8)) & 0x00ff00ff
    v = (v | (v << 4)) & 0x0f0f0f0f
    v = (v | (v << 2)) & 0x33333333
    return (v | (v << 1)) & 0x55555555

def swizzle(raw, side, reverse=False):
    n = max(1, side // 4); result = bytearray(len(raw))
    assert len(raw) == n * n * 16
    for y in range(n):
        for x in range(n):
            z = ((spread(x) << 1) | spread(y)) * 16
            linear = (y*n+x) * 16
            dst, src = (linear, z) if reverse else (z, linear)
            result[dst:dst+16] = raw[src:src+16]
    return bytes(result)

def decode_texture(b):
    assert b[:8] == b'PSP2TX02' and b[32:36] == b'GXT\0'
    assert struct.unpack_from('<II', b, 80) == (0, 0x87000000)
    w, h = struct.unpack_from('<HH', b, 88); assert w == h
    buf = io.BytesIO(); Image.new('RGBA', (4, 4)).save(buf, format='DDS', pixel_format='DXT5')
    header = bytearray(buf.getvalue()[:128]); struct.pack_into('<III', header, 12, h, w, w*h)
    raw = swizzle(b[96:96+w*h], w, reverse=True)
    image = Image.open(io.BytesIO(header + raw)); image.load()
    return image.convert('RGBA')

def encode_texture(image, original):
    result = bytearray(original[:96]); side = image.width
    mip_count = struct.unpack_from('<I', original, 92)[0]
    for mip in range(mip_count):
        size = max(1, side >> mip)
        im = image if mip == 0 else image.resize((size, size), Image.Resampling.LANCZOS)
        # BC3 always allocates at least a 4x4 block.
        if size < 4:
            block = Image.new('RGBA', (4, 4)); block.paste(im); im = block
        buffer = io.BytesIO(); im.save(buffer, format='DDS', pixel_format='DXT5')
        dds = buffer.getvalue(); assert dds[84:88] == b'DXT5'
        result += swizzle(dds[128:], size)
    assert len(result) == len(original)
    return bytes(result)

def read_font(b):
    assert b[:4] == b'FNT0'
    pages, count = struct.unpack_from('<HH', b, 4)
    start = 16 + pages * 32
    assert len(b) == start + count * 14
    glyphs = {}
    for i in range(count):
        c = chr(struct.unpack_from('<I', b, start + count*10 + i*4)[0])
        assert c not in glyphs
        glyphs[c] = b[start+i*10:start+(i+1)*10]
    assert list(glyphs) == sorted(glyphs)
    return pages, start, glyphs

def digest(b): return hashlib.sha256(b).hexdigest()

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--archive', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--font', type=Path, default=Path('/System/Library/Fonts/STHeiti Medium.ttc'))
    args = parser.parse_args(); args.output.mkdir(parents=True, exist_ok=True)
    assert args.archive.resolve() != (args.output/'patch.bin').resolve()
    index = archive_index(args.archive)
    def get(name):
        entry = index[name]
        with args.archive.open('rb') as f:
            f.seek(entry['offset']); b = f.read(entry['size'])
        assert len(b) == entry['size']; return b
    name = 'game/strings/onscreen.ch.strings.bsp'; source = get(name)
    assert source[:16] == MAGIC
    records = read_tlv(source[16:]); assert len(records) == 5162
    assert MAGIC + write_tlv(records) == source
    cc = OpenCC('t2s'); converted = []; texts = []; character_set = set()
    for tag, record in records:
        assert tag == 75
        fields = read_tlv(record); assert [t for t,v in fields] == [1,2,3,4,5]
        text = fields[-1][1].decode('utf8'); assert not text or text.endswith('\0')
        simple = cc.convert(text)
        assert len(text) == len(simple)  # this build changes script, not layout
        character_set.update(c for c in simple if ord(c) >= 32)
        texts.append({'key':fields[3][1][:-1].decode(), 'before':text[:-1], 'after':simple[:-1]})
        converted.append((tag, write_tlv(fields[:-1]+[(5, simple.encode())])))
    changes = {name: MAGIC + write_tlv(converted)}
    # Full round trip: identity, numeric IDs and all markup remain intact.
    assert len(changes[name]) == len(source)
    for old, new in zip(records, read_tlv(changes[name][16:])):
        assert read_tlv(old[1])[:4] == read_tlv(new[1])[:4]
    # Dialogue is not in onscreen.ch.strings.bsp. Each Chinese voice bank
    # carries subtitle field 7 alongside IDs, speaker, timing and audio data.
    # Keep every non-text field byte-exact, including empty subtitle records.
    subtitle_names = sorted(n for n in index if '/vo/banks/ch/' in n and n.endswith('.bsp'))
    assert len(subtitle_names) == 190
    base_index = archive_index(args.archive.with_name('gamedata.bin'))
    assert {n for n in base_index if '/vo/banks/ch/' in n} <= set(subtitle_names)
    subtitle_records = 0
    for subtitle_name in subtitle_names:
        original = get(subtitle_name)
        assert original[:16] == MAGIC
        original_records = read_tlv(original[16:])
        assert MAGIC + write_tlv(original_records) == original
        revised = []
        for tag, record in original_records:
            assert tag == 74
            fields = read_tlv(record)
            assert [t for t, v in fields] == list(range(1, 17))
            raw = fields[6][1]
            text = raw.decode('utf8')
            assert not text or text.endswith('\0')
            simple = cc.convert(text)
            assert len(simple.encode('utf8')) == len(raw)
            character_set.update(c for c in simple if ord(c) >= 32)
            texts.append({'asset': subtitle_name, 'key': fields[0][1].hex(),
                          'before': text.removesuffix('\0'), 'after': simple.removesuffix('\0')})
            new_fields = fields[:6] + [(7, simple.encode('utf8'))] + fields[7:]
            assert new_fields[:6] + new_fields[7:] == fields[:6] + fields[7:]
            revised.append((tag, write_tlv(new_fields)))
            subtitle_records += 1
        changes[subtitle_name] = MAGIC + write_tlv(revised)
        assert len(changes[subtitle_name]) == len(original)
    assert subtitle_records == 8093
    _, _, original_glyphs = read_font(get('game/ui/fonts/ch/default.bsfnt'))
    # Keep unchanged punctuation/Latin/CJK, plus every character in actual text.
    targets = character_set | {c for c in original_glyphs if cc.convert(c) == c}
    missing_simplified = targets - original_glyphs.keys()
    # A table entry alone does not prove that the game has a visible glyph.
    # The original fonts contain an empty 3x3 slot for 噻 used by a later line.
    required_cjk = {c for c in character_set if '\u3400' <= c <= '\u9fff'}
    blank_original = set()
    for kind in ['default', 'small']:
        pages, _, glyphs = read_font(get(f'game/ui/fonts/ch/{kind}.bsfnt'))
        textures = [decode_texture(get(f'game/ui/fonts/ch/{kind}_{i}.bstex')) for i in range(pages)]
        for c in required_cjk & glyphs.keys():
            page,w,h,dx,dy,advance,x,y = struct.unpack('<BBBbbBHH', glyphs[c])
            if not w or not h or textures[page].getchannel('A').crop((x,y,x+w,y+h)).getextrema()[1] == 0:
                blank_original.add(c)
    missing = missing_simplified | blank_original
    available = sorted(original_glyphs.keys() - targets)
    assignment = {}
    for c in sorted(missing):
        donor = next((x for x in available if cc.convert(x) == c), None)
        if donor is None: donor = next(x for x in available if '\u4e00' <= x <= '\u9fff')
        assignment[c] = donor; available.remove(donor)
    cmap = TTFont(args.font, fontNumber=0).getBestCmap()
    assert all(ord(c) in cmap for c in missing), 'Missing source font glyphs'
    render_font = ImageFont.truetype(str(args.font), 128, index=0)
    preview_glyphs = {}
    for kind in ['default', 'small']:
        font_name = f'game/ui/fonts/ch/{kind}.bsfnt'; font_data = get(font_name)
        pages, start, glyphs = read_font(font_data)
        assert glyphs.keys() == original_glyphs.keys()
        texture_names = [f'game/ui/fonts/ch/{kind}_{i}.bstex' for i in range(pages)]
        texture_bytes = [get(n) for n in texture_names]
        textures = [decode_texture(b) for b in texture_bytes]
        changed_rects = [[] for _ in textures]
        new_glyphs = dict((c, glyphs[c]) for c in targets if c in glyphs)
        for c, donor in assignment.items():
            entry = glyphs[donor]; page,w,h,dx,dy,advance,x,y = struct.unpack('<BBBbbBHH', entry)
            assert w > 0 and h > 0 and x+w <= textures[page].width and y+h <= textures[page].height
            box = render_font.getbbox(c)
            canvas = Image.new('RGBA', (box[2]-box[0],box[3]-box[1]))
            ImageDraw.Draw(canvas).text((-box[0],-box[1]),c,font=render_font,fill=(255,255,255,255))
            glyph = canvas.resize((w,h),Image.Resampling.LANCZOS)
            textures[page].paste(glyph,(x,y))
            changed_rects[page].append((x,y,w,h))
            new_glyphs[c] = entry
        assert set(new_glyphs) == targets
        header = bytearray(font_data[:start]); struct.pack_into('<H',header,6,len(targets))
        order = sorted(targets)
        changes[font_name] = bytes(header) + b''.join(new_glyphs[c] for c in order) + b''.join(struct.pack('<I',ord(c)) for c in order)
        assert set(read_font(changes[font_name])[2]) >= character_set
        for i,n in enumerate(texture_names):
            encoded = bytearray(encode_texture(textures[i],texture_bytes[i]))
            # Keep untouched level-0 BC3 blocks byte-exact to avoid lossy
            # recompression of the game's original glyphs. Lower mips rebuild.
            side = textures[i].width
            changed_blocks = set()
            for x,y,w,h in changed_rects[i]:
                for by in range(y//4,(y+h-1)//4+1):
                    for bx in range(x//4,(x+w-1)//4+1):changed_blocks.add((spread(bx)<<1)|spread(by))
            for block in range(side*side//16):
                if block not in changed_blocks:
                    off=96+block*16;encoded[off:off+16]=texture_bytes[i][off:off+16]
            changes[n]=bytes(encoded)
            textures[i]=decode_texture(changes[n])
        for c in required_cjk:
            page,w,h,dx,dy,advance,x,y = struct.unpack('<BBBbbBHH', new_glyphs[c])
            assert w and h and textures[page].getchannel('A').crop((x,y,x+w,y+h)).getextrema()[1] > 0, (kind,c)
        if kind=='default':
            for c in '触碰即可开始新历险继续游戏选项存档字幕神秘海域黄金深渊哇噻':
                entry=new_glyphs[c];page,w,h,dx,dy,adv,x,y=struct.unpack('<BBBbbBHH',entry)
                preview_glyphs[c]=textures[page].crop((x,y,x+w,y+h))
    preview=Image.new('RGBA',(660,260),(25,30,38,255));draw=ImageDraw.Draw(preview)
    for row,line in enumerate(['触碰即可开始','开始新历险  继续游戏','选项  存档  字幕','神秘海域  黄金深渊','哇噻']):
        x=18
        for c in line:
            if c==' ':x+=18;continue
            glyph=preview_glyphs[c];preview.alpha_composite(glyph,(x,14+row*48));x+=34
    preview.convert('RGB').save(args.output/'simplified-font-preview.png')
    destination=args.output/'patch.bin';shutil.copyfile(args.archive,destination)
    manifest=[]
    with destination.open('r+b') as f:
        for name,b in changes.items():
            entry=index[name];assert len(b)<=entry['size'], name
            f.seek(entry['offset']);f.write(b);f.write(b'\0'*(entry['size']-len(b)))
            f.seek(48+entry['index']*12+4);f.write(struct.pack('<I',len(b)))
            manifest.append({'name':name,'offset':entry['offset'],'before_size':entry['size'],'size':len(b),'before_sha256':digest(get(name)),'sha256':digest(b)})
    rebuilt=archive_index(destination)
    assert rebuilt.keys()==index.keys()
    with args.archive.open('rb') as src,destination.open('rb') as dst:
        for name,old in index.items():
            new=rebuilt[name];src.seek(old['offset']);dst.seek(new['offset'])
            expected=changes[name] if name in changes else src.read(old['size'])
            assert dst.read(new['size'])==expected,name
    report={'title_id':'PCSD00001','version':'1.03','patch_revision':3,'menu_records':len(records),'subtitle_banks':len(subtitle_names),'subtitle_records':subtitle_records,'records':len(records)+subtitle_records,'changed_strings':sum(t['before']!=t['after'] for t in texts),'font_characters':len(targets),'new_simplified_glyphs':len(missing_simplified),'repaired_original_blank_glyphs':sorted(blank_original),'required_cjk_glyphs':len(required_cjk),'all_required_cjk_glyphs_nonempty_in_both_fonts':True,'all_menu_and_dialogue_characters_in_both_fonts':True,'subtitle_non_text_fields_byte_identical':True,'changed_entries':manifest,'all_other_entries_byte_identical':True,'source_sha256':digest(args.archive.read_bytes()),'output_sha256':digest(destination.read_bytes()),'device_validation':'pending'}
    (args.output/'manifest.json').write_text(json.dumps(report,ensure_ascii=False,indent=2))
    (args.output/'text-conversion.json').write_text(json.dumps(texts,ensure_ascii=False,indent=2))
    print(json.dumps({k:v for k,v in report.items() if k!='changed_entries'},ensure_ascii=False,indent=2))

if __name__=='__main__': main()
