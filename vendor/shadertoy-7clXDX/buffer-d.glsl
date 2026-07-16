const float PI = 3.14159;
#define intensity intensity_func()


ivec2 D_to_DD(int index) {
    ivec2 i = ivec2(iResolution.xy);
    int lim = i.x*i.y;
    int index_clamp = clamp(index, 0, lim);
    int x = index_clamp%i.x;
    int y = index_clamp/i.x;
    return ivec2(x,y);
}
float intensity_func() {
    vec4 samp = texelFetch(iChannel2, D_to_DD(1), 0);
    return samp.x;
}

// kernals -----------

float kernel_spike(vec2 uv, float skips) {
    float dist = length(uv)/(sqrt(skips*skips + skips*skips));
    float b = -abs(dist)+1.;
    b *= b;
    b *= b;
    b *= b;

    return b;
}
float kernel(vec2 uv, float skips) {
    float dist = length(uv)/(sqrt(skips*skips + skips*skips));
    float b = cos(dist*(PI/2.));
    b *= b;

    return b;
}

// sampling -----------

vec2 uvOut(vec2 fragCoord, vec2 disp) {
    vec2 uv = (fragCoord+disp)/iResolution.xy;
    //uv.x *= (iResolution.x/iResolution.y);
    
    return uv;
}

vec3 call(vec2 uv) { // main shader
    vec2 fragCoord = uv*iResolution.xy;
    vec3 col = texture(iChannel0, uv).xyz;
    float vighetting = kernel((uv*2.-1.)/2., 1.)+0.2;
    vighetting = mix(1. ,vighetting, min(intensity, 1.));
    
    col *= vighetting;
    return col;
}

// filters -----------

float hash_uv(vec2 p) {
	vec3 p3  = fract(vec3(p.xyx) * .1031);
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.x + p3.y) * p3.z);
}

vec3 tint(float brightness) {
    vec3 a = vec3(0.8, 1.1, 0.7)*brightness;
    vec3 b = vec3(0.8, 0.8, 1.8)*(1.-brightness);
    return a+b;
}
float grey(vec3 col) {
    return (col.x+col.y+col.z)/3.;
}
vec3 saturate_and_noise(vec3 col, float amount, vec2 fragCoord) {
    vec3 saturated = col*amount + 0.5*(1.-amount);
    vec3 noisy = saturated + hash_uv(round(fragCoord/10.)+iTime)/40.;
    return noisy;
}

// convolutions -----------

vec3 blur(vec2 fragCoord) {
    float x_scan = 30.;
    float y_scan = 10.;
    float x_skew = 5.;
    vec3 total = vec3(0.);
    float weighting = 0.;
    float skips = intensity*2.;
    float tint_intensity = min(intensity, 1.);
    
    for (float y=-y_scan; y<y_scan; y++) {
        for (float x=-x_scan/x_skew; x<x_scan; x++) {
            vec2 pos = vec2(x*skips, y*skips);
            vec3 samp = call(uvOut(fragCoord,pos));
            //float weight = kernel(pos/size);
            float weight = kernel_spike(vec2(pos.x/x_scan, pos.y/y_scan), skips);
            
            
            
            float brightness = grey(samp);
            //brightness /= 2.;
            
            vec3 tint = tint(brightness)*tint_intensity+(1.-tint_intensity);
            total += samp*weight*brightness*tint;
            weighting += weight*brightness;
        }
    }
    return total/weighting;
}
vec3 sharpening(vec2 fragCoord) {
    float size = 6.; // these amount of samples would be unpractical. 8 is a good midground. 
    float skips = intensity;
    float factor = 0.1;
    float acutance = 0.;
    vec3 base = call(uvOut(fragCoord, vec2(0.)));
    
    for (float y=-size; y<size; y++) {
        for (float x=-size; x<size; x++) {
            vec2 pos = vec2(x*skips, y*skips);
            vec3 samp = call(uvOut(fragCoord,pos));
            float weight = kernel(pos/size, skips);
            
            acutance += grey((base-samp)*weight);
        }
    }
    return base+acutance*factor;
}

// image -----------

vec3 image(vec2 fragCoord) {
    //float intensity = 0.01;
    vec3 col = blur(fragCoord);
    //float grey = grey(call(uvOut(fragCoord,vec2(0.))));
    float grey = grey(sharpening(fragCoord));
    //float grey = 1.;
    grey += 0.7; // increase brightness.
    col = saturate_and_noise(col * grey, 0.9, fragCoord)*intensity+col*(1.-intensity);
    
    return col;
}

vec3 box(vec2 a, vec2 b, vec2 fragCoord, float scroll, float scope) { 
    vec2 diff = (abs(a-b));
    vec2 mid_point = (a+b)/2.;
    vec2 relative_to_mid = abs(mid_point-fragCoord);
    
    if (relative_to_mid.x > diff.x/2. || relative_to_mid.y > diff.y/2.) {
        return vec3(0.);
    } else {
        vec2 uv = ((fragCoord-vec2(0.,scroll))-a)/(abs(a-b));
        uv.y = 1.-uv.y;
        uv.y *= diff.y/(diff.x*scope);
        uv.y = 1.-uv.y;
        
        return vec3(uv, 0.);
    }
    return vec3(0.);
}
void mainImage( out vec4 fragColor, in vec2 fragCoord )
{

    fragColor = vec4(0.);
    vec2 a_2 = vec2(0.);
    vec2 b_2 = vec2(iResolution.x, iResolution.y*0.885);
    if (iFrame % 2 == 1) {
        if (sin(fragCoord.y) < 0.) {
            fragColor = vec4(image(fragCoord),1.0);
        } else {
            if (within(a_2, b_2, fragCoord)) {
                fragColor = texture(iChannel1, uvOut(fragCoord.xy, vec2(0.)));
            }
        }
    } else {
        if (sin(fragCoord.y) < 0.) {
            if (within(a_2, b_2, fragCoord)) {
                fragColor = texture(iChannel1, uvOut(fragCoord.xy, vec2(0.)));
            }
        } else {
            fragColor = vec4(image(fragCoord),1.0);
        }
    }
    //fragColor = vec4(image(fragCoord),1.0);
}