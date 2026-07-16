ivec2 D_to_DD(int index) {
    ivec2 i = ivec2(iResolution.xy);
    int lim = i.x*i.y;
    int index_clamp = clamp(index, 0, lim);
    int x = index_clamp%i.x;
    int y = index_clamp/i.x;
    return ivec2(x,y);
}
vec4 commit(vec2 fragCoord, int index_p, vec4 payload, vec4 original) {
    int index = int(fragCoord.x)+int(fragCoord.y)*int(iResolution.x);
    if (index_p == index) {
        return payload;
    }
    return original;
}
vec4 watch(vec2 fragCoord) {
    int index = int(fragCoord.x)+int(fragCoord.y)*int(iResolution.x);
    vec4 original = texelFetch(iChannel0, ivec2(fragCoord), 0);
    if (iMouse.z > 0.) {
        vec4 payload = texelFetch(iChannel1, ivec2(iMouse.xy), 0); // x is payload, y is index
        if (int(round(payload.y)) == index && int(round(payload.w)) > 0) {
            return vec4(payload.x, original.y, original.z, original.w);
        } //else if (int(round(payload.y)) == index && int(round(payload.w)) == 2) {
        //    return vec4(original.x, original.y, payload.x, payload.z);
        //}
    }
    return original;
}
vec4 as_n_read_from_n(vec2 fragCoord, int dst, int scr, vec4 original) {
    int index = int(fragCoord.x)+int(fragCoord.y)*int(iResolution.x);
    if (index == dst) {
        vec4 src_samp = texelFetch(iChannel0, D_to_DD(scr), 0);
        return vec4(src_samp.x, original.y, original.z, original.w);
    }
    return original;
}
void mainImage( out vec4 fragColor, in vec2 fragCoord ) {
    //int index = int(fragCoord.x)+int(fragCoord.y)*int(iResolution.x);

    if (iFrame == 1) {
        fragColor = vec4(0.);
        fragColor = commit(fragCoord.xy, 0, 
        vec4(0., 1., 3., 2.), fragColor);
        
        fragColor = commit(fragCoord.xy, 1, 
        vec4(1., 2., 0., 1.5), fragColor);
        
        //
      
        fragColor = commit(fragCoord.xy, 12, // scroll bar
        vec4(1., 0., 0., 0.), fragColor);
        
    } else {
        fragColor = watch(fragCoord);
        int index = int(fragCoord.x)+int(fragCoord.y)*int(iResolution.x);

        fragColor = as_n_read_from_n(fragCoord.xy, 0,1, fragColor);
        if (index == 1) {
            bool idle = (iMouse.x == 0. || iMouse.y == 0.);
            if (idle) {
                float animate = ((cos(iTime/1.)+1.)/2.)*1.5+0.01;
                fragColor = commit(fragCoord.xy, 1,
                vec4(animate, 2., 0., 1.5), fragColor);
            }
        }
    }
}
    // x: id of data, y: carry index, z: burn, w: burn_length
    // x: data, y: id of 1, z: n from d, w: n from d
    // x: data, y: id of 2, z: leftmost range, w: rightmost range 
    // x: bool, y: id of 3, z: nothing, w: nothing