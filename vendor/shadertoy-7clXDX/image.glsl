#define intensity intensity_func()

ivec2 D_to_DD(int index) {
    ivec2 i = ivec2(iResolution.xy);
    int lim = i.x*i.y;
    int index_clamp = clamp(index, 0, lim);
    int x = index_clamp%i.x;
    int y = index_clamp/i.x;
    return ivec2(x,y);
}
vec2 uvOut(vec2 fragCoord, vec2 disp) {
    vec2 uv = (fragCoord+disp)/iResolution.xy;
    //uv.x *= (iResolution.x/iResolution.y);
    return uv;
}
vec3 saturate(vec3 col, float amount) {
    vec3 saturated = col*amount + 0.5*(1.-amount);
    return saturated;
}
vec3 tint(float brightness) {
    vec3 a = vec3(0.9, 1.1, 0.9)*brightness;
    vec3 b = vec3(0.9, 0.9, 1.2)*(1.-brightness);
    return a+b;
}
float intensity_func() {
    vec4 samp = texelFetch(iChannel1, D_to_DD(1), 0);
    return samp.x;
}
void mainImage( out vec4 fragColor, in vec2 fragCoord ) {

    vec2 uv = uvOut(fragCoord, vec2(0.));
    //float intensity = 0.;
    float x_scroll = iTime*50000.;
    float y_scroll = iTime*150.;

    vec2 uvread = vec2((fragCoord.x+x_scroll)/500., (fragCoord.y+y_scroll)/6.);
    float glitch = texture(iChannel2, uvOut(uvread, vec2(0.))).x;
    float glitch_mask = clamp(glitch, 0., 1.);
    glitch_mask = round(glitch_mask);

    vec2 uvread2 = vec2((fragCoord.x+x_scroll)/200., (fragCoord.y+y_scroll)*1.);
    float scratch = texture(iChannel2, uvOut(uvread2, vec2(0.))).x;
    scratch = smoothstep(0.45, 0.55, scratch);
    float whiteout = glitch_mask*(scratch+glitch);

    vec2 uvread3 = vec2((fragCoord.x+x_scroll)/10., (fragCoord.y+y_scroll)*1.);
    whiteout += whiteout*texture(iChannel3, uvOut(uvread3, vec2(0.))).x;
    whiteout *= whiteout;

    float corona = abs(uv.y*2.-1.);
    corona *= corona;
    //corona /= 1.;
    float bottom_deggredation = -((uv.y*2.-1.)+0.7)*5.;
    bottom_deggredation = clamp(bottom_deggredation, 0., 1.)*2.;
    whiteout = whiteout/2.*corona + bottom_deggredation*(glitch+scratch);
    vec3 deggredation = 1.-tint(whiteout);

    uv.x -= (whiteout/10.)*intensity;
    vec3 col = vec3(0.);
    col = texture(iChannel0, uv).xyz;
    col = saturate(col, mix(1. ,(1.-clamp(scratch/10., 0., 1.)), intensity));
    //col *= 1.-(deggredation*2.);
    col = clamp(col, 0., 1.);
    col += (deggredation)*intensity;
    col += (whiteout/3.)*intensity;
    fragColor = vec4(col, -1.);
    //fragColor = color_new/1.;
}