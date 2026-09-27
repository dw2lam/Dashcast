"""Renders the office composite's board and MacBook in the office photo's own camera.

    Blender -b --python render_macbook.py -- board   <out.png> [samples]
    Blender -b --python render_macbook.py -- macbook <out.png> [samples]

Camera: the photo's fitted pinhole (prep_office.py): 3000×2000, f = 2000 px, principal point (1490, 690),
looking straight down the car, border-rendered to the office crop (150, 560)–(2850, 2000). Car frame
(x → passenger, y ↓, z → forward, metres) → Blender world (X = x, Y = z, Z = -y).

board:   the trunk's subfloor cover as a bevelled, carpeted slab, 0.96 × 0.33 m × 12 mm, from under the
         steering wheel rim (driver side) to the passenger side; the rim (from the photo's fitted ellipse) is in
         the scene only to cast its contact shadow on it. (Shadow catchers on the seats and armrest were tried:
         with this stand-in lighting they drew hard-edged bands, so the board casts onto nothing below it.)
macbook: "MacBook Pro M3 16 Inch 2024" by jackbaeten (CC BY 4.0, refs/macbook), open at its modelled ~112°,
         our Mac desktop on its display, its lid-back logo and base engraving hidden, on the board's passenger
         end. The board is a shadow catcher here, so the MacBook's shadow lands on the carpet.
Both: soft daylight through the glass roof and windshield, a dim cabin fill, Cycles + denoising, RGBA with the
shadows in alpha. prep_office.py applies the photo's correction homography, grades and grains them.
"""
import math
import os
import sys

import bpy
from mathutils import Vector

argv = sys.argv[sys.argv.index('--') + 1:] if '--' in sys.argv else []
MODE = argv[0] if argv else 'macbook'
OUT = argv[1] if len(argv) > 1 else f'/tmp/{MODE}.png'
SAMPLES = int(argv[2]) if len(argv) > 2 else 96
HERE = os.path.dirname(os.path.abspath(__file__))
BLEND = os.path.join(HERE, 'refs/macbook/source/Sketchfab_2024_02_08_15_50_33.blend')
DISPLAY_TEX = os.path.join(HERE, 'macbook-display.png')

W, H, F, CX, CY = 3000, 2000, 2000.0, 1490.0, 690.0
CROP = (150, 560, 2850, 2000)

# The board (car frame, metres): its top surface, extent, and thickness.
BOARD = {'x0': -0.43, 'x1': 0.535, 'z0': 0.98, 'z1': 1.31, 'y': 0.333, 't': 0.012}
# The steering wheel, from the photo's fitted rim ellipse: centre, radius, tilt (top toward the windshield).
WHEEL = {'c': (-0.397, 0.142, 1.186), 'r': 0.185, 'tube': 0.017, 'tilt': 21}
# The MacBook's footprint on the board: centre x, front edge z.
MAC = {'x': 0.35, 'zf': 1.02}


def car(x, y, z):
    return Vector((x, z, -y))


def scene():
    bpy.ops.wm.read_factory_settings(use_empty=True)
    sc = bpy.context.scene
    sc.render.engine = 'CYCLES'
    sc.cycles.samples = SAMPLES
    sc.cycles.use_denoising = True
    sc.cycles.device = 'CPU'
    sc.render.film_transparent = True
    sc.render.resolution_x, sc.render.resolution_y = W, H
    sc.render.resolution_percentage = 100
    sc.render.use_border = True
    sc.render.use_crop_to_border = True
    sc.render.border_min_x, sc.render.border_max_x = CROP[0] / W, CROP[2] / W
    sc.render.border_min_y, sc.render.border_max_y = 1 - CROP[3] / H, 1 - CROP[1] / H
    sc.view_settings.view_transform = 'Standard'
    # The cabin is dim: expose for the photo's mid-tones, not for a product shot.
    sc.view_settings.exposure = -1.6 if MODE == 'board' else -1.8
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


def material(name, color, rough, sheen=0.0):
    m = bpy.data.materials.new(name)
    m.use_nodes = True
    b = m.node_tree.nodes['Principled BSDF']
    b.inputs['Base Color'].default_value = (*color, 1)
    b.inputs['Roughness'].default_value = rough
    if sheen and 'Sheen Weight' in b.inputs:
        b.inputs['Sheen Weight'].default_value = sheen
    return m


def carpet():
    """Black automotive needle-felt: dark, fully rough, a little sheen, fine fibre bump."""
    m = material('carpet', (0.0040, 0.0045, 0.0055), 1.0, sheen=0.06)
    nt = m.node_tree
    b = nt.nodes['Principled BSDF']
    # Fibre has no mirror sheen at grazing angles (the camera sees the board almost edge-on).
    if 'Specular IOR Level' in b.inputs:
        b.inputs['Specular IOR Level'].default_value = 0.0
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


def wheel(sc):
    """The rim, where the photo shows it: casts its shadow and contact, never seen by the camera."""
    w = WHEEL
    bpy.ops.mesh.primitive_torus_add(major_radius=w['r'], minor_radius=w['tube'], major_segments=96, minor_segments=16)
    ob = bpy.context.active_object
    ob.location = car(*w['c'])
    # Torus lies in XY; stand it up facing the driver (normal toward -Y world), then tilt its top forward.
    ob.rotation_euler = (math.radians(90 - w['tilt']), 0, 0)
    ob.visible_camera = False
    ob.data.materials.append(material('rim', (0.02, 0.02, 0.02), 0.6))


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
    # A thin glossy coat over the picture, so the cabin reflects in the glass.
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
        if o is None:
            continue
        sc.collection.objects.link(o)
    for o in dst.objects:
        if o is not None and o.parent is None:
            o.parent = root
    # The model is in centimetres with its front toward -Y and the lid toward +Y: scale to metres, no turn.
    root.scale = (0.01, 0.01, 0.01)
    bpy.context.view_layer.update()
    meshes = [o for o in dst.objects if o is not None and o.type == 'MESH']
    pts = [o.matrix_world @ Vector(c) for o in meshes for c in o.bound_box]
    lo = Vector((min(p.x for p in pts), min(p.y for p in pts), min(p.z for p in pts)))
    hi = Vector((max(p.x for p in pts), max(p.y for p in pts), max(p.z for p in pts)))
    # Base footprint: the base group spans y -12.4…12.4 cm; put its front on MAC.zf and its bottom on the board.
    base_front = -0.1237
    target = car(MAC['x'], BOARD['y'], MAC['zf'])
    root.location = Vector((target.x - (lo.x + hi.x) / 2, target.y - base_front, target.z - lo.z))
    dm = display_material()
    for o in meshes:
        if o.name == 'VQmfhbMzfNAuKAD':
            o.data.materials.clear()
            o.data.materials.append(dm)
        if o.name in ('vttfLwUKvlhvIxZ', 'MSvtIRGpODFmbIn', 'XFrrJGMTkvjIPfX'):
            o.hide_render = True
        if o.name == 'yIwQWXMhgFCUjXk':
            o.hide_render = True
    return root


def main():
    sc = scene()
    camera(sc)
    lights(sc)
    if MODE == 'board':
        board(sc)
        wheel(sc)
    else:
        board(sc, catcher=True)
        macbook(sc)
    sc.render.filepath = OUT
    bpy.ops.render.render(write_still=True)


main()
