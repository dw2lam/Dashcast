"""The office composite's 3D scene, rendered through the office photo's own camera.

    Blender -b --python render_office.py -- board   <out.png> [samples]
    Blender -b --python render_office.py -- macbook <out.png> [samples]
    Blender -b --python render_office.py -- swivel  <out dir>  [frames]

Camera: the photo's fitted pinhole (prep_office.py): 3000×2000, f = 2000 px, principal point (1490, 690),
looking straight down the car. Car frame (x → passenger, y ↓, z → forward, metres) → Blender world
(X = x, Y = z, Z = -y). Renders are in this "model" camera; prep_office.py maps them onto the photo with the
screen's correction homography (HC), grades and grains them.

board:   the trunk's subfloor cover, a bevelled carpeted slab 1.22 × 0.39 m × 12 mm at lap height, entirely
         below the steering wheel: its top 8.4 cm under the rim's lowest point (wheel fitted from the photo's rim
         through HC⁻¹: centre (−0.41, 0.15, 1.23) m, 38 cm, tilted 20°), and its far edge ~28 px below the rim
         in the image, so the two never overlap. It runs from under the wheel to near the passenger door.
macbook: "MacBook Pro M3 16 Inch 2024" by jackbaeten (CC BY 4.0, refs/macbook) scaled ×0.94 (between the 14"
         and 16" footprints: 33.4 × 23.3 cm), open at its modelled ~112°, our Mac desktop on its display, its logo and engravings hidden,
         on the board's passenger end; the board is a shadow catcher, so its shadow lands on the carpet.
swivel:  the car's screen as a real slab (the photo's own glass on its face, dark satin plastic sides and
         back, a stalk), turned 0→30° toward the passenger about its mount, in front of the photo projected
         from the camera (window coordinates) with the part the screen hid filled along the dash's bands.
         Per frame: the picture (A), the slab's shadow on the dash (B, shadow catchers) and the slab's mask
         (C). prep_office.py keeps only what changed and blends it into the photo.
"""
import math
import os
import sys

import bpy
from mathutils import Matrix, Vector

argv = sys.argv[sys.argv.index('--') + 1:] if '--' in sys.argv else []
MODE = argv[0] if argv else 'macbook'
OUT = argv[1] if len(argv) > 1 else f'/tmp/{MODE}.png'
ARG = int(argv[2]) if len(argv) > 2 else 0
HERE = os.path.dirname(os.path.abspath(__file__))
SCRATCH = os.environ.get('OFFICE_SCRATCH', '/tmp')
BLEND = os.path.join(HERE, 'refs/macbook/source/Sketchfab_2024_02_08_15_50_33.blend')
DISPLAY_TEX = os.path.join(HERE, 'macbook-display.png')

W, H, F, CX, CY = 3000, 2000, 2000.0, 1490.0, 690.0
CROP = (150, 560, 2850, 2000)
# The swivel's render window in model px (the screen's neighbourhood; prep_office.py maps it to the photo).
SWIVEL_WIN = (1150, 680, 1830, 1190)

BOARD = {'x0': -0.58, 'x1': 0.64, 'z0': 1.00, 'z1': 1.39, 'y': 0.415, 't': 0.012}
MAC = {'x': 0.447, 'zf': 1.04, 'scale': 0.94}
# The screen (model space): outer glass centre, size, and the mount's pivot behind it.
SCREEN = {'c': (-0.00535, 0.14686, 1.37462), 'w': 0.368, 'h': 0.24153, 'depth': 0.02, 'pivot': 0.035}
TURN = 30.0


def car(x, y, z):
    return Vector((x, z, -y))


def scene(samples, scale=100, exposure=0.0, border=CROP):
    bpy.ops.wm.read_factory_settings(use_empty=True)
    sc = bpy.context.scene
    sc.render.engine = 'CYCLES'
    sc.cycles.samples = samples
    sc.cycles.use_denoising = True
    sc.cycles.device = 'CPU'
    # A 1-px box filter: each pixel averages only its own footprint, so the projected photo isn't softened.
    sc.cycles.pixel_filter_type = 'BOX'
    sc.cycles.filter_width = 1.0
    sc.render.film_transparent = True
    sc.render.dither_intensity = 0.0
    sc.render.resolution_x, sc.render.resolution_y = W, H
    sc.render.resolution_percentage = scale
    sc.render.use_border = True
    sc.render.use_crop_to_border = True
    sc.render.border_min_x, sc.render.border_max_x = border[0] / W, border[2] / W
    sc.render.border_min_y, sc.render.border_max_y = 1 - border[3] / H, 1 - border[1] / H
    sc.view_settings.view_transform = 'Standard'
    sc.view_settings.exposure = exposure
    sc.render.image_settings.file_format = 'PNG'
    sc.render.image_settings.color_mode = 'RGBA'
    sc.render.image_settings.color_depth = '16'
    return sc


def camera(sc):
    cam = bpy.data.cameras.new('photo')
    cam.sensor_fit = 'HORIZONTAL'
    cam.sensor_width = 36.0
    cam.lens = F / W * 36.0
    cam.shift_x = (W / 2 - CX) / W
    cam.shift_y = (CY - H / 2) / W
    cam.clip_start = 0.05
    cam.clip_end = 50
    ob = bpy.data.objects.new('photo', cam)
    ob.rotation_euler = (math.radians(90), 0, 0)
    sc.collection.objects.link(ob)
    sc.camera = ob


def area(sc, name, loc, rot, size, energy, color):
    L = bpy.data.lights.new(name, 'AREA')
    L.shape = 'RECTANGLE'
    L.size, L.size_y = size
    L.energy = energy
    L.color = color
    ob = bpy.data.objects.new(name, L)
    ob.location = loc
    ob.rotation_euler = rot
    sc.collection.objects.link(ob)


def lights(sc):
    world = bpy.data.worlds.new('cabin')
    world.use_nodes = True
    bg = world.node_tree.nodes['Background']
    bg.inputs[0].default_value = (0.11, 0.115, 0.125, 1)
    bg.inputs[1].default_value = 1.1
    sc.world = world
    # The glass roof overhead and the windshield ahead: big, soft, cool daylight.
    area(sc, 'roof', car(0.0, -0.75, 1.0), (0, 0, 0), (1.2, 1.4), 70, (0.94, 0.97, 1.0))
    area(sc, 'windshield', car(0.1, -0.45, 2.0), (math.radians(-65), 0, 0), (1.5, 0.6), 110, (0.93, 0.96, 1.0))


def material(name, color, rough, sheen=0.0, spec=None):
    m = bpy.data.materials.new(name)
    m.use_nodes = True
    b = m.node_tree.nodes['Principled BSDF']
    b.inputs['Base Color'].default_value = (*color, 1)
    b.inputs['Roughness'].default_value = rough
    if sheen and 'Sheen Weight' in b.inputs:
        b.inputs['Sheen Weight'].default_value = sheen
    if spec is not None and 'Specular IOR Level' in b.inputs:
        b.inputs['Specular IOR Level'].default_value = spec
    return m


def carpet():
    """Black automotive needle-felt: dark, fully rough, no mirror sheen at grazing angles, fine fibre bump."""
    m = material('carpet', (0.0040, 0.0045, 0.0055), 1.0, sheen=0.06, spec=0.0)
    nt = m.node_tree
    b = nt.nodes['Principled BSDF']
    noise = nt.nodes.new('ShaderNodeTexNoise')
    noise.inputs['Scale'].default_value = 900
    noise.inputs['Detail'].default_value = 8
    bump = nt.nodes.new('ShaderNodeBump')
    bump.inputs['Strength'].default_value = 0.35
    bump.inputs['Distance'].default_value = 0.0006
    nt.links.new(noise.outputs['Fac'], bump.inputs['Height'])
    nt.links.new(bump.outputs['Normal'], b.inputs['Normal'])
    return m


def board(sc, catcher=False):
    b = BOARD
    bpy.ops.mesh.primitive_cube_add(size=1)
    ob = bpy.context.active_object
    ob.name = 'board'
    ob.scale = (b['x1'] - b['x0'], b['z1'] - b['z0'], b['t'])
    ob.location = car((b['x0'] + b['x1']) / 2, b['y'] + b['t'] / 2, (b['z0'] + b['z1']) / 2)
    bpy.ops.object.transform_apply(scale=True)
    bev = ob.modifiers.new('bevel', 'BEVEL')
    bev.width = 0.004
    bev.segments = 4
    ob.data.materials.append(carpet())
    ob.is_shadow_catcher = catcher
    return ob


def display_material():
    m = bpy.data.materials.new('dashcast-display')
    m.use_nodes = True
    nt = m.node_tree
    nt.nodes.clear()
    out = nt.nodes.new('ShaderNodeOutputMaterial')
    em = nt.nodes.new('ShaderNodeEmission')
    em.inputs['Strength'].default_value = 3.0
    tex = nt.nodes.new('ShaderNodeTexImage')
    tex.image = bpy.data.images.load(DISPLAY_TEX)
    nt.links.new(tex.outputs['Color'], em.inputs['Color'])
    glass = nt.nodes.new('ShaderNodeBsdfGlossy')
    glass.inputs['Roughness'].default_value = 0.08
    fres = nt.nodes.new('ShaderNodeFresnel')
    fres.inputs['IOR'].default_value = 1.5
    mix = nt.nodes.new('ShaderNodeMixShader')
    nt.links.new(fres.outputs['Fac'], mix.inputs['Fac'])
    nt.links.new(em.outputs['Emission'], mix.inputs[1])
    nt.links.new(glass.outputs['BSDF'], mix.inputs[2])
    nt.links.new(mix.outputs['Shader'], out.inputs['Surface'])
    return m


def macbook(sc):
    with bpy.data.libraries.load(BLEND, link=False) as (src, dst):
        dst.objects = list(src.objects)
    root = bpy.data.objects.new('macbook', None)
    sc.collection.objects.link(root)
    for o in dst.objects:
        if o is not None:
            sc.collection.objects.link(o)
    for o in dst.objects:
        if o is not None and o.parent is None:
            o.parent = root
    # Centimetres, front toward -Y, lid toward +Y: to metres at the 14" footprint, no turn.
    s = 0.01 * MAC['scale']
    root.scale = (s, s, s)
    bpy.context.view_layer.update()
    meshes = [o for o in dst.objects if o is not None and o.type == 'MESH']
    pts = [o.matrix_world @ Vector(c) for o in meshes for c in o.bound_box]
    lo = Vector((min(p.x for p in pts), min(p.y for p in pts), min(p.z for p in pts)))
    hi = Vector((max(p.x for p in pts), max(p.y for p in pts), max(p.z for p in pts)))
    base_front = -12.37 * s
    target = car(MAC['x'], BOARD['y'], MAC['zf'])
    root.location = Vector((target.x - (lo.x + hi.x) / 2, target.y - base_front, target.z - lo.z))
    dm = display_material()
    for o in meshes:
        if o.name == 'VQmfhbMzfNAuKAD':
            o.data.materials.clear()
            o.data.materials.append(dm)
        if o.name in ('vttfLwUKvlhvIxZ', 'MSvtIRGpODFmbIn', 'XFrrJGMTkvjIPfX', 'yIwQWXMhgFCUjXk'):
            o.hide_render = True
    return root


# ---- swivel ----------------------------------------------------------------------------------------------

def image_emission(name, path, window=False, strength=1.0, alpha=False, interp='Linear'):
    m = bpy.data.materials.new(name)
    m.use_nodes = True
    nt = m.node_tree
    nt.nodes.clear()
    out = nt.nodes.new('ShaderNodeOutputMaterial')
    em = nt.nodes.new('ShaderNodeEmission')
    em.name = 'emission'
    em.inputs['Strength'].default_value = strength
    tex = nt.nodes.new('ShaderNodeTexImage')
    tex.name = 'image'
    tex.image = bpy.data.images.load(path)
    tex.interpolation = interp
    tex.extension = 'EXTEND'
    if window:
        coord = nt.nodes.new('ShaderNodeTexCoord')
        nt.links.new(coord.outputs['Window'], tex.inputs['Vector'])
    nt.links.new(tex.outputs['Color'], em.inputs['Color'])
    shader = em.outputs['Emission']
    if alpha:
        # The glass: a glossy coat over the picture (its weight animated with the turn), and the rounded corners.
        gloss = nt.nodes.new('ShaderNodeBsdfGlossy')
        gloss.inputs['Roughness'].default_value = 0.06
        gloss.inputs['Color'].default_value = (0.9, 0.93, 1.0, 1)
        coat = nt.nodes.new('ShaderNodeMixShader')
        coat.name = 'coat'
        coat.inputs['Fac'].default_value = 0.0
        nt.links.new(shader, coat.inputs[1])
        nt.links.new(gloss.outputs['BSDF'], coat.inputs[2])
        clear = nt.nodes.new('ShaderNodeBsdfTransparent')
        cut = nt.nodes.new('ShaderNodeMixShader')
        nt.links.new(tex.outputs['Alpha'], cut.inputs['Fac'])
        nt.links.new(clear.outputs['BSDF'], cut.inputs[1])
        nt.links.new(coat.outputs['Shader'], cut.inputs[2])
        shader = cut.outputs['Shader']
    nt.links.new(shader, out.inputs['Surface'])
    return m


def swivel_scene(face_path):
    sc = scene(48, scale=200, exposure=0.0, border=SWIVEL_WIN)
    camera(sc)
    lights(sc)
    s = SCREEN
    # The photo, projected from the camera onto a backdrop far behind (model space, the screen area filled).
    bpy.ops.mesh.primitive_plane_add(size=1)
    back = bpy.context.active_object
    back.name = 'backdrop'
    back.scale = (40, 30, 1)
    back.location = car(0, 0, 12)
    back.rotation_euler = (math.radians(90), 0, 0)
    back.data.materials.append(image_emission('photo', os.path.join(SCRATCH, 'swivel-backdrop.png'), window=True, interp='Closest'))
    back.visible_shadow = False
    # The dash behind the screen, for the slab's shadow: its face and its top.
    catchers = []
    for loc, rot, size in [
        (car(s['c'][0], 0.16, s['c'][2] + 0.09), (math.radians(90), 0, 0), (1.3, 0.32)),
        (car(s['c'][0], -0.01, s['c'][2] + 0.30), (0, 0, 0), (1.3, 0.42)),
    ]:
        bpy.ops.mesh.primitive_plane_add(size=1)
        p = bpy.context.active_object
        p.scale = (size[0], size[1], 1)
        p.location = loc
        p.rotation_euler = rot
        p.is_shadow_catcher = True
        catchers.append(p)
    # The screen: a pivot at the mount, a bevelled satin-plastic body, the glass face, a stalk.
    pivot = bpy.data.objects.new('pivot', None)
    sc.collection.objects.link(pivot)
    pivot.location = car(s['c'][0], s['c'][1], s['c'][2] + s['pivot'])
    satin = material('satin', (0.006, 0.006, 0.007), 0.7)
    bpy.ops.mesh.primitive_cube_add(size=1)
    body = bpy.context.active_object
    body.scale = (s['w'] - 0.001, s['depth'], s['h'] - 0.001)
    bpy.ops.object.transform_apply(scale=True)
    body.location = Vector((0, -s['pivot'] + s['depth'] / 2 + 0.0004, 0))
    bev = body.modifiers.new('round', 'BEVEL')
    bev.width = 0.006
    bev.segments = 6
    body.data.materials.append(satin)
    bpy.ops.mesh.primitive_plane_add(size=1)
    face = bpy.context.active_object
    face.scale = (s['w'], s['h'], 1)
    face.rotation_euler = (math.radians(90), 0, 0)
    face.location = Vector((0, -s['pivot'], 0))
    face.data.materials.append(image_emission('glass', face_path, alpha=True))
    bpy.ops.mesh.primitive_cylinder_add(radius=0.022, depth=0.08, vertices=48)
    stalk = bpy.context.active_object
    stalk.rotation_euler = (math.radians(90), 0, 0)
    stalk.location = Vector((0, 0.03, -0.05))
    stalk.data.materials.append(satin)
    slab = [body, face, stalk]
    for o in slab:
        o.parent = pivot
    return sc, back, catchers, slab, pivot, face.data.materials[0]


def ease(t):
    """tesla.com's --tds-bezier (0.5, 0, 0, 0.75), as the turn's pace."""
    lo, hi = 0.0, 1.0
    for _ in range(40):
        u = (lo + hi) / 2
        x = 3 * u * (1 - u) ** 2 * 0.5 + 3 * u * u * (1 - u) * 0.0 + u ** 3
        if x < t:
            lo = u
        else:
            hi = u
    u = (lo + hi) / 2
    return 3 * u * (1 - u) ** 2 * 0.0 + 3 * u * u * (1 - u) * 0.75 + u ** 3


def render_swivel(outdir, frames):
    os.makedirs(outdir, exist_ok=True)
    jobs = [('ui', os.path.join(SCRATCH, 'swivel-face-ui.png'), frames), ('desk', os.path.join(SCRATCH, 'swivel-face-desk.png'), 1)]
    for tag, face_path, n in jobs:
        sc, back, catchers, slab, pivot, glass = swivel_scene(face_path)
        angles = [TURN * ease(i / (n - 1)) for i in range(n)] if n > 1 else [TURN]
        if tag == 'ui':
            angles = [0.0] + angles  # frame "0" twice: once as the 0° shadow reference
        for i, a in enumerate(angles):
            t = a / TURN
            pivot.rotation_euler = (0, 0, math.radians(a))
            glass.node_tree.nodes['coat'].inputs['Fac'].default_value = 0.025 * t
            glass.node_tree.nodes['emission'].inputs['Strength'].default_value = 1.0 - 0.08 * t
            name = f'{tag}-{i:02d}' if tag == 'ui' and i else (f'{tag}-ref' if tag == 'ui' else f'{tag}-end')
            # A: the picture.
            sc.render.film_transparent = False
            sc.cycles.samples = 48
            back.hide_render = False
            for c in catchers:
                c.hide_render = True
            for o in slab:
                o.visible_camera = True
            sc.render.filepath = os.path.join(outdir, f'A-{name}.png')
            bpy.ops.render.render(write_still=True)
            # B: the slab's shadow on the dash.
            sc.render.film_transparent = True
            sc.cycles.samples = 24
            back.hide_render = True
            for c in catchers:
                c.hide_render = False
            for o in slab:
                o.visible_camera = False
            sc.render.filepath = os.path.join(outdir, f'B-{name}.png')
            bpy.ops.render.render(write_still=True)
            # C: the slab's mask.
            sc.cycles.samples = 16
            for c in catchers:
                c.hide_render = True
            for o in slab:
                o.visible_camera = True
            sc.render.filepath = os.path.join(outdir, f'C-{name}.png')
            bpy.ops.render.render(write_still=True)


def main():
    if MODE == 'swivel':
        render_swivel(OUT, ARG or 27)
        return
    sc = scene(ARG or 128, exposure=-1.6 if MODE == 'board' else -1.8)
    camera(sc)
    lights(sc)
    if MODE == 'board':
        board(sc)
    else:
        board(sc, catcher=True)
        macbook(sc)
    sc.render.filepath = OUT
    bpy.ops.render.render(write_still=True)


main()
