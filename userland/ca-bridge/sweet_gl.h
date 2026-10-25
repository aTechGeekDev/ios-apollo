/*
 * What eagl.c asks of the OpenGL ES library behind it besides the gl* functions: see
 * sweet_gl_osmesa.c, the one implementation there is. HackiOS's userland/src/redwood_gl.h
 * (Copyright (c) 2026 OOSEX GANG, MIT License, see LICENSE.HackiOS), names made ours.
 */
#ifndef SWEET_GL_H
#define SWEET_GL_H

struct sweet_gl;

struct sweet_gl *sweet_gl_create(int version);              /* a context of OpenGL ES 2 or 3; NULL: none to be had */
int sweet_gl_make_current(struct sweet_gl *gl);             /* ... the calling thread's (NULL: none); 0 on failure */
void sweet_gl_destroy(struct sweet_gl *gl);
const char *sweet_gl_library(void);                           /* for the log */

/*
 * The texture bound to GL_TEXTURE_2D made of an IOSurface's own memory: what is drawn into the
 * texture is in the surface, what is in the surface is what the texture shows, and nobody copies.
 * For a library whose driver can do that (a GPU's) and a surface it can do it with. 0: not
 * done; the texture is to be filled and read back with OpenGL ES calls.
 */
int sweet_gl_surface_texture(struct sweet_gl *gl, uint32_t surface);

/*
 * CoreAnimation draws a layer's pixels with one of ninety "functions" (a fragment shader each); these
 * are the names its Metal renderer has for them, four characters a function, in their order.
 */
#define SWEET_CA_FUNCTIONS \
	"clr img ida cim cid mua m1a lrp lrc lra add spl s1a cma bds bco bim c33 c3b c4b c4p c3a c3x c4x bia grl ds4 ds6 " \
	"ds8 ups db2 db4 nb7 n11 n15 n19 n23 n27 vrd vrb sb3 axl rad rac con vcm vdk vlt map mpc crv hue clm hom opa met " \
	"srl ega sdr alt p3c edr hrm lut ovr ovl lub aup alm stl pc0 pc1 prc psl ps0 ps1 psm psr pcr pbl peo bib asg a75 " \
	"a50 atc ipc apl 3dl cst "

#endif
