# Offline preview renderer for tools/environment-preview/export.luau output.
# Development aid only (approximate ShadowMap-style lighting; NOT Roblox's renderer).
# Requires: python -m pip install moderngl numpy pillow
# Usage: python render.py scene.json[,more.json] cameras.json outdir
import json, math, sys, os
import numpy as np
import moderngl
from PIL import Image, ImageDraw, ImageFont

MATS = ["SmoothPlastic", "Plastic", "Grass", "LeafyGrass", "Ground", "Sand", "Concrete", "Brick", "Asphalt",
        "Pavement", "Metal", "DiamondPlate", "Glass", "Wood", "WoodPlanks", "Fabric", "Slate", "Plaster",
        "RoofShingles", "ClayRoofTiles", "Cobblestone", "Rock", "Basalt", "Snow", "Neon", "Marble", "Granite",
        "Limestone", "Sandstone", "CeramicTiles", "Rubber", "Carpet", "Foil", "CorrodedMetal", "Pebble", "Mud",
        "Water", "Glacier", "Ice", "Leather", "Cardboard", "Salt"]
MAT_ID = {m: i for i, m in enumerate(MATS)}


def box_tris():
    c = np.array([[x, y, z] for x in (-.5, .5) for y in (-.5, .5) for z in (-.5, .5)])
    faces = [(0, 1, 3, 2, (-1, 0, 0)), (4, 6, 7, 5, (1, 0, 0)), (0, 4, 5, 1, (0, -1, 0)),
             (2, 3, 7, 6, (0, 1, 0)), (0, 2, 6, 4, (0, 0, -1)), (1, 5, 7, 3, (0, 0, 1))]
    v, n = [], []
    for a, b, cc, d, nn in faces:
        for t in ((a, b, cc), (a, cc, d)):
            for i in t:
                v.append(c[i]); n.append(nn)
    return np.array(v, 'f4'), np.array(n, 'f4')


def wedge_tris():
    # Roblox WedgePart: full bottom (-Y) and back (+Z); slope from top-back to bottom-front.
    A = (-.5, -.5, -.5); B = (.5, -.5, -.5); C = (-.5, -.5, .5); D = (.5, -.5, .5)
    E = (-.5, .5, .5); F = (.5, .5, .5)
    s = 1 / math.sqrt(2)
    quads = [((A, B, D, C), (0, -1, 0)), ((C, D, F, E), (0, 0, 1)), ((A, E, F, B), (0, s, -s))]
    tris = [((A, C, E), (-1, 0, 0)), ((B, F, D), (1, 0, 0))]
    v, n = [], []
    for q, nn in quads:
        for t in ((q[0], q[1], q[2]), (q[0], q[2], q[3])):
            for p in t:
                v.append(p); n.append(nn)
    for t, nn in tris:
        for p in t:
            v.append(p); n.append(nn)
    return np.array(v, 'f4'), np.array(n, 'f4')


def cyl_tris(seg=20):
    v, n = [], []
    for i in range(seg):
        a0 = 2 * math.pi * i / seg; a1 = 2 * math.pi * (i + 1) / seg
        y0, z0, y1, z1 = .5 * math.cos(a0), .5 * math.sin(a0), .5 * math.cos(a1), .5 * math.sin(a1)
        n0 = (0, math.cos(a0), math.sin(a0)); n1 = (0, math.cos(a1), math.sin(a1))
        quad = [((-.5, y0, z0), n0), ((.5, y0, z0), n0), ((.5, y1, z1), n1), ((-.5, y1, z1), n1)]
        for t in ((0, 1, 2), (0, 2, 3)):
            for k in t:
                v.append(quad[k][0]); n.append(quad[k][1])
        for x, nn in ((-.5, (-1, 0, 0)), (.5, (1, 0, 0))):
            v += [(x, 0, 0), (x, y0, z0), (x, y1, z1)]; n += [nn] * 3
    return np.array(v, 'f4'), np.array(n, 'f4')


def sphere_tris(us=18, vs=10):
    v, n = [], []
    def p(i, j):
        th = math.pi * j / vs; ph = 2 * math.pi * i / us
        return (math.sin(th) * math.cos(ph), math.cos(th), math.sin(th) * math.sin(ph))
    for i in range(us):
        for j in range(vs):
            a, b, c, d = p(i, j), p(i + 1, j), p(i + 1, j + 1), p(i, j + 1)
            for t in ((a, b, c), (a, c, d)):
                for q in t:
                    v.append(tuple(.5 * x for x in q)); n.append(q)
    return np.array(v, 'f4'), np.array(n, 'f4')


TEMPL = {"Block": box_tris(), "Wedge": wedge_tris(), "Cylinder": cyl_tris(), "Ball": sphere_tris(),
         "Ellipsoid": sphere_tris()}

VS = """
#version 330
uniform mat4 vp; uniform mat4 lvp;
in vec3 in_pos; in vec3 in_nrm; in vec4 in_col; in float in_mat;
out vec3 w; out vec3 nrm; out vec4 col; out float mat; out vec4 lpos;
void main(){ w=in_pos; nrm=in_nrm; col=in_col; mat=in_mat; lpos=lvp*vec4(in_pos,1.0); gl_Position=vp*vec4(in_pos,1.0);}
"""
FS = """
#version 330
uniform vec3 sun; uniform vec3 cam; uniform sampler2DShadow smap; uniform float haze; uniform vec3 hazecol;
uniform float shadowOn;
in vec3 w; in vec3 nrm; in vec4 col; in float mat; in vec4 lpos;
out vec4 frag;
float h(vec2 p){ return fract(sin(dot(p,vec2(127.1,311.7)))*43758.5453); }
float vn(vec2 p){ vec2 i=floor(p); vec2 f=fract(p); f=f*f*(3.0-2.0*f);
  return mix(mix(h(i),h(i+vec2(1,0)),f.x),mix(h(i+vec2(0,1)),h(i+vec2(1,1)),f.x),f.y); }
void main(){
  vec3 n=normalize(nrm); if(!gl_FrontFacing) n=-n;
  vec3 c=col.rgb; int m=int(mat+0.5);
  vec2 q = abs(n.y)>0.5 ? w.xz : (abs(n.x)>0.5 ? w.zy : w.xy);
  float nz = vn(q*0.35)*0.6+vn(q*1.7)*0.4;
  if(m==2||m==3){ c*=0.86+0.24*nz; }            // grass
  else if(m==4||m==5||m==35){ c*=0.88+0.2*nz; } // ground/sand/mud
  else if(m==6||m==9||m==8){ c*=0.93+0.1*nz; }  // concrete/pavement/asphalt
  else if(m==7){ vec2 b=q*vec2(1.0,2.0); b.x+=step(1.0,mod(b.y,2.0))*0.5; vec2 f=fract(b);
     c*= (f.x<0.06||f.y<0.08)?0.78:(0.95+0.1*h(floor(b))); }
  else if(m==18||m==19){ c*= 0.85+0.2*step(0.5,fract(q.y*1.2)); }
  else if(m==21||m==22){ c*=0.8+0.35*nz; }
  vec3 sh = lpos.xyz/lpos.w*0.5+0.5; float lit=1.0;
  if(shadowOn>0.5 && sh.x>0.0&&sh.x<1.0&&sh.y>0.0&&sh.y<1.0){
    lit=0.0; vec2 ts=1.0/vec2(textureSize(smap,0));
    for(int x=-1;x<=1;x++)for(int y=-1;y<=1;y++) lit+=texture(smap,vec3(sh.xy+vec2(x,y)*ts,sh.z-0.0015));
    lit/=9.0; }
  float ndl=max(dot(n,sun),0.0);
  vec3 sky=vec3(0.62,0.72,0.88), gnd=vec3(0.42,0.40,0.36);
  vec3 amb=mix(gnd,sky,n.y*0.5+0.5)*0.55;
  vec3 rgb=c*(amb+vec3(1.0,0.96,0.88)*1.05*ndl*lit);
  if(m==24){ rgb=c*1.6; }
  if(m==10||m==11||m==12||m==36||m==32){ vec3 v=normalize(cam-w); vec3 r=reflect(-v,n);
     float sp=pow(max(dot(r,sun),0.0), m==12||m==36 ? 80.0 : 24.0)*lit;
     rgb+= vec3(sp)*(m==12||m==36?0.9:0.35);
     if(m==12||m==36){ rgb=mix(rgb, mix(vec3(0.55,0.65,0.78),sky,clamp(r.y,0.0,1.0)), 0.35); } }
  float d=length(w-cam); float f=1.0-exp(-d*haze);
  rgb=mix(rgb,hazecol,clamp(f,0.0,0.92));
  frag=vec4(pow(rgb,vec3(1.0/1.15)),col.a);
}
"""
SVS = """
#version 330
uniform mat4 lvp; in vec3 in_pos; void main(){ gl_Position=lvp*vec4(in_pos,1.0);} """
SFS = """
#version 330
void main(){} """
TVS = """
#version 330
uniform mat4 vp; in vec3 in_pos; in vec2 in_uv; out vec2 uv; out vec3 w;
void main(){ uv=in_uv; w=in_pos; gl_Position=vp*vec4(in_pos,1.0);} """
TFS = """
#version 330
uniform sampler2D tex; uniform vec3 cam; uniform float haze; uniform vec3 hazecol; in vec2 uv; in vec3 w; out vec4 frag;
void main(){ vec4 t=texture(tex,uv); if(t.a<0.05) discard; float d=length(w-cam); float f=1.0-exp(-d*haze);
 frag=vec4(mix(t.rgb,hazecol,clamp(f,0.0,0.92)),t.a);} """
SKY_VS = """
#version 330
in vec2 in_pos; out vec2 p; void main(){ p=in_pos; gl_Position=vec4(in_pos,0.9999,1.0);} """
SKY_FS = """
#version 330
uniform mat4 ivp; uniform vec3 sun; uniform vec3 hazecol; in vec2 p; out vec4 frag;
void main(){ vec4 a=ivp*vec4(p,1.0,1.0); vec3 d=normalize(a.xyz/a.w);
  float t=clamp(d.y,0.0,1.0); vec3 top=vec3(0.28,0.52,0.86); vec3 c=mix(hazecol,top,pow(t,0.55));
  float s=max(dot(d,sun),0.0); c+=vec3(1.0,0.9,0.7)*pow(s,600.0)*1.5+vec3(1.0,0.85,0.6)*pow(s,12.0)*0.12;
  if(d.y<0.0) c=mix(hazecol,vec3(0.45,0.5,0.45),clamp(-d.y*4.0,0.0,1.0));
  frag=vec4(pow(c,vec3(1.0/1.15)),1.0);} """


def perspective(fovy, aspect, near, far):
    f = 1 / math.tan(math.radians(fovy) / 2)
    m = np.zeros((4, 4), 'f4')
    m[0, 0] = f / aspect; m[1, 1] = f; m[2, 2] = (far + near) / (near - far); m[2, 3] = 2 * far * near / (near - far)
    m[3, 2] = -1
    return m


def look_at(eye, target, up=(0, 1, 0)):
    eye = np.array(eye, 'f8'); target = np.array(target, 'f8'); up = np.array(up, 'f8')
    f = target - eye; f /= np.linalg.norm(f)
    s = np.cross(f, up); s /= np.linalg.norm(s)
    u = np.cross(s, f)
    m = np.identity(4, 'f4')
    m[0, :3] = s; m[1, :3] = u; m[2, :3] = -f
    m[0, 3] = -s.dot(eye); m[1, 3] = -u.dot(eye); m[2, 3] = f.dot(eye)
    return m


def ortho(l, r, b, t, n, f):
    m = np.identity(4, 'f4')
    m[0, 0] = 2 / (r - l); m[1, 1] = 2 / (t - b); m[2, 2] = -2 / (f - n)
    m[0, 3] = -(r + l) / (r - l); m[1, 3] = -(t + b) / (t - b); m[2, 3] = -(f + n) / (f - n)
    return m


def build_mesh(parts, opaque):
    pos, nrm, col, mat = [], [], [], []
    groups = {}
    for p in parts:
        shape = p[0]
        alpha = 1 - p[20]
        if (alpha >= 0.999) != opaque or alpha <= 0.01:
            continue
        groups.setdefault(shape, []).append(p)
    for shape, ps in groups.items():
        tv, tn = TEMPL[shape]
        arr = np.array([q[1:19] for q in ps], 'f4')
        P = arr[:, 0:3]; R = arr[:, 3:12].reshape(-1, 3, 3); S = arr[:, 12:15]; C = arr[:, 15:18] / 255.0
        if shape == "Ball":
            d = S.min(axis=1); S = np.stack([d, d, d], 1)
        if shape == "Cylinder":
            d = np.minimum(S[:, 1], S[:, 2]); S = np.stack([S[:, 0], d, d], 1)
        v = tv[None, :, :] * S[:, None, :]
        v = np.einsum('nij,nkj->nki', R, v) + P[:, None, :]
        nn = tn[None, :, :] / np.maximum(S[:, None, :], 1e-4)
        nn = np.einsum('nij,nkj->nki', R, nn)
        nn /= np.linalg.norm(nn, axis=2, keepdims=True) + 1e-9
        k = tv.shape[0]
        a = np.array([1 - q[20] for q in ps], 'f4')
        m = np.array([MAT_ID.get(q[19], 0) for q in ps], 'f4')
        pos.append(v.reshape(-1, 3)); nrm.append(nn.reshape(-1, 3))
        col.append(np.repeat(np.concatenate([C, a[:, None]], 1), k, 0)); mat.append(np.repeat(m, k))
    if not pos:
        return None
    return (np.concatenate(pos).astype('f4'), np.concatenate(nrm).astype('f4'),
            np.concatenate(col).astype('f4'), np.concatenate(mat).astype('f4'))


FONT_CACHE = {}


def font(size, bold=True):
    key = (size, bold)
    if key not in FONT_CACHE:
        for name in (["ariblk.ttf", "arialbd.ttf"] if bold else ["arialbd.ttf"]):
            try:
                FONT_CACHE[key] = ImageFont.truetype(name, size); break
            except Exception:
                continue
    return FONT_CACHE[key]


def sign_texture(text, fg, bg, w, h):
    W = 512; H = max(32, int(W * h / max(w, 1e-3)))
    if H > 1024:
        H = 1024; W = max(32, int(H * w / h))
    img = Image.new('RGBA', (W, H), (tuple(int(x) for x in bg) + (255,)) if bg else (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    lines = text.split("\n")
    size = int(H / len(lines) * 0.7)
    while size > 6:
        f = font(size)
        widths = [d.textbbox((0, 0), l, font=f)[2] for l in lines]
        if max(widths) <= W * 0.92:
            break
        size -= 2
    f = font(size)
    y = (H - size * len(lines) * 1.15) / 2
    for l in lines:
        bb = d.textbbox((0, 0), l, font=f)
        d.text(((W - bb[2]) / 2, y), l, font=f, fill=tuple(int(x) for x in fg) + (255,))
        y += size * 1.15
    return img


def main():
    scene = {"parts": [], "signs": []}
    for f in sys.argv[1].split(","):
        s = json.load(open(f)); scene["parts"] += s["parts"]; scene["signs"] += s.get("signs", [])
    cams = json.load(open(sys.argv[2]))
    out = sys.argv[3]
    os.makedirs(out, exist_ok=True)
    W, H = cams.get("width", 1600), cams.get("height", 900)
    ctx = moderngl.create_standalone_context()
    prog = ctx.program(vertex_shader=VS, fragment_shader=FS)
    sprog = ctx.program(vertex_shader=SVS, fragment_shader=SFS)
    tprog = ctx.program(vertex_shader=TVS, fragment_shader=TFS)
    skyprog = ctx.program(vertex_shader=SKY_VS, fragment_shader=SKY_FS)
    parts = scene["parts"]
    meshes = []
    for opaque in (True, False):
        m = build_mesh(parts, opaque)
        if m is None:
            meshes.append(None); continue
        p, n, c, mt = m
        vbo = ctx.buffer(np.concatenate([p, n, c, mt[:, None]], 1).astype('f4').tobytes())
        vao = ctx.vertex_array(prog, [(vbo, '3f 3f 4f 1f', 'in_pos', 'in_nrm', 'in_col', 'in_mat')])
        svao = ctx.vertex_array(sprog, [(vbo, '3f 12x 16x 4x', 'in_pos')])
        meshes.append((vao, svao, len(p)))
    # signs
    signs = []
    for s in scene.get("signs", []):
        px, py, pz = s["p"]; R = np.array(s["r"], 'f4').reshape(3, 3); w, h = s["w"], s["h"]
        img = sign_texture(s["text"], s["fg"], None, w, h)
        tex = ctx.texture(img.size, 4, img.transpose(Image.FLIP_TOP_BOTTOM).tobytes())
        tex.build_mipmaps(); tex.filter = (moderngl.LINEAR_MIPMAP_LINEAR, moderngl.LINEAR)
        tex.anisotropy = 8.0
        corners = np.array([[-w / 2, -h / 2, 0], [w / 2, -h / 2, 0], [w / 2, h / 2, 0], [-w / 2, h / 2, 0]], 'f4')
        wc = (R @ corners.T).T + np.array([px, py, pz])
        uv = np.array([[0, 0], [1, 0], [1, 1], [0, 1]], 'f4')
        idx = [0, 1, 2, 0, 2, 3]
        data = np.concatenate([wc[idx], uv[idx]], 1).astype('f4')
        vbo = ctx.buffer(data.tobytes())
        signs.append((ctx.vertex_array(tprog, [(vbo, '3f 2f', 'in_pos', 'in_uv')]), tex))
    quad = ctx.buffer(np.array([-1, -1, 1, -1, 1, 1, -1, -1, 1, 1, -1, 1], 'f4').tobytes())
    skyvao = ctx.vertex_array(skyprog, [(quad, '2f', 'in_pos')])
    sun = np.array(cams.get("sun", [0.45, 0.75, 0.5]), 'f4'); sun /= np.linalg.norm(sun)
    hazecol = cams.get("hazecol", [0.74, 0.82, 0.92])
    SM = 4096
    shadow_tex = ctx.depth_texture((SM, SM))
    shadow_tex.compare_func = '<='
    shadow_tex.repeat_x = shadow_tex.repeat_y = False
    shadow_fbo = ctx.framebuffer(depth_attachment=shadow_tex)
    msfbo = ctx.framebuffer(color_attachments=[ctx.renderbuffer((W, H), 4, samples=8)],
                            depth_attachment=ctx.depth_renderbuffer((W, H), samples=8))
    outfbo = ctx.framebuffer(color_attachments=[ctx.texture((W, H), 4)])
    for cam in cams["cameras"]:
        eye = np.array(cam["eye"], 'f4'); tgt = np.array(cam["target"], 'f4')
        fov = cam.get("fov", 55); far = cam.get("far", 60000.0); near = cam.get("near", max(0.3, 0.0025 * float(np.linalg.norm(np.array(cam["target"]) - np.array(cam["eye"])))))
        V = look_at(eye, tgt); Pm = perspective(fov, W / H, near, far)
        VP = (Pm @ V)
        # shadow region around a focus point
        focus = np.array(cam.get("shadowFocus", tgt), 'f4'); rad = cam.get("shadowRadius", 400.0)
        LV = look_at(focus + sun * 4000, focus, (0, 1, 0) if abs(sun[1]) < 0.99 else (0, 0, 1))
        LP = ortho(-rad, rad, -rad, rad, 10, 9000)
        LVP = LP @ LV
        shadow_fbo.use(); shadow_fbo.clear(depth=1.0)
        ctx.enable(moderngl.DEPTH_TEST); ctx.disable(moderngl.CULL_FACE)
        sprog['lvp'].write(LVP.T.astype('f4').tobytes())
        if meshes[0]:
            meshes[0][1].render()
        msfbo.use(); ctx.clear(0.7, 0.8, 0.9, 1.0, depth=1.0)
        ctx.disable(moderngl.DEPTH_TEST)
        ivp = np.linalg.inv(VP.astype('f8') @ np.diag([1, 1, 1, 1]))
        # sky uses direction only: remove translation
        V0 = V.copy(); V0[:3, 3] = 0
        ivp = np.linalg.inv((Pm @ V0).astype('f8')).astype('f4')
        skyprog['ivp'].write(ivp.T.tobytes()); skyprog['sun'].value = tuple(sun); skyprog['hazecol'].value = tuple(hazecol)
        skyvao.render()
        ctx.enable(moderngl.DEPTH_TEST)
        haze = cam.get("haze", cams.get("haze", 0.00012))
        prog['vp'].write(VP.T.astype('f4').tobytes()); prog['lvp'].write(LVP.T.astype('f4').tobytes())
        prog['sun'].value = tuple(sun); prog['cam'].value = tuple(eye); prog['haze'].value = haze
        prog['hazecol'].value = tuple(hazecol); prog['shadowOn'].value = 1.0
        shadow_tex.use(0); prog['smap'].value = 0
        if meshes[0]:
            meshes[0][0].render()
        tprog['vp'].write(VP.T.astype('f4').tobytes()); tprog['cam'].value = tuple(eye)
        tprog['haze'].value = haze; tprog['hazecol'].value = tuple(hazecol)
        ctx.enable(moderngl.BLEND); ctx.blend_func = moderngl.SRC_ALPHA, moderngl.ONE_MINUS_SRC_ALPHA
        for vao, tex in signs:
            tex.use(1); tprog['tex'].value = 1; vao.render()
        if meshes[1]:
            ctx.depth_mask = False
            meshes[1][0].render()
            ctx.depth_mask = True
        ctx.disable(moderngl.BLEND)
        ctx.copy_framebuffer(outfbo, msfbo)
        img = Image.frombytes('RGBA', (W, H), outfbo.color_attachments[0].read()).transpose(Image.FLIP_TOP_BOTTOM)
        img.convert('RGB').save(os.path.join(out, cam["name"] + ".png"))
        print("wrote", cam["name"])


if __name__ == "__main__":
    main()
