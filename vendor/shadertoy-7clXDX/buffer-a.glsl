const float PI = 3.14159;


// ---------------------------------------------------------------------------------------------
// windows
// ---------------------------------------------------------------------------------------------

ivec2 D_to_DD(int index) {
    ivec2 i = ivec2(iResolution.xy);
    int lim = i.x*i.y;
    int index_clamp = clamp(index, 0, lim);
    int x = index_clamp%i.x;
    int y = index_clamp/i.x;
    return ivec2(x,y);
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
vec4 slider(vec2 a, vec2 b, vec2 fragCoord, int data_index) {
    vec2 uv = (fragCoord-a)/(abs(a-b));
    vec4 data_samp = texelFetch(iChannel2, D_to_DD(data_index), 0);
    float range = data_samp.x;
    
    vec3 color = vec3(0.1);

    color += (1.-vec3(smoothstep(0.09,0.1,abs(uv.y-range))))/2.;
    if (ivec2(fragCoord.xy) == ivec2(iMouse.xy) && iMouse.z > 0.) {
        float mouse_range = (iMouse.y-a.y)/(abs(a.y-b.y));
        return vec4(mouse_range, data_index, 0., 5.);
    }
    return vec4(color, 0.);
}
vec4 window(vec2 a, vec2 b, vec2 fragCoord, int data_index, float scroll_range, float scope) {
    float scroll = texelFetch(iChannel2, D_to_DD(data_index), 0).x;
    scroll = 1.-scroll;
    scroll *= scroll_range;
    vec3 color = vec3(0.5);

    vec2 diff = (abs(a-b));
    vec2 mid_point = (a+b)/2.;
    vec2 relative_to_mid = abs(mid_point-fragCoord);
    
    vec2 b_relative_to_mid = relative_to_mid-b;
    vec2 a_relative_to_mid = relative_to_mid-a;

    vec2 boarder_partition_b = vec2(
    b.x+3.*sign(b_relative_to_mid.x)
    , b.y+3.*sign(b_relative_to_mid.y));
    
    vec2 boarder_partition_a = vec2(
    a.x+3.*sign(a_relative_to_mid.x)
    , a.y-3.*sign(a_relative_to_mid.y));

    vec2 box_partition_b = boarder_partition_b+vec2(0.*sign(b_relative_to_mid.x), 0.);
    vec2 box_partition_a = boarder_partition_a;
    
    vec2 slider_partition_b = boarder_partition_b;
    vec2 slider_partition_a = vec2(box_partition_b.x, boarder_partition_a.y);
    
    if (within(a, b, fragCoord)) {
        if (within(boarder_partition_a, boarder_partition_b, fragCoord)) {
            if (within(box_partition_a, box_partition_b, fragCoord)) {
                color = box(box_partition_a, box_partition_b, fragCoord, scroll, scope);
                return vec4(color, 1.);
            } else {
                return slider(slider_partition_a, slider_partition_b, fragCoord, data_index);
            }
        } else {
            return vec4(color, 0.);
        }
    } else {
        return vec4(0.);
    }
    return vec4(0.);
}

// ---------------------------------------------------------------------------------------------
// gui
// ---------------------------------------------------------------------------------------------

vec2 uvOut(vec2 fragCoord, vec2 disp) {
    vec2 uv = (fragCoord+disp)/iResolution.xy;
    //uv.x *= (iResolution.x/iResolution.y);
    return uv;
}
float kernel(vec2 uv, float skips) {
    float dist = length(uv)/(sqrt(skips*skips + skips*skips));
    float b = cos(dist*(PI/2.));
    b *= b;

    return b;
}
vec3 glyph_sample(vec2 uv, float index) {
    //vec2 uv = fragCoord/iResolution.xy;
    vec2 index_uv = vec2(uv.x+mod(index, 16.), uv.y+floor(index/16.));
    index_uv = index_uv/16.;
    return texture(iChannel0, index_uv).xyz;
}
vec3 refine(vec2 fragCoord, float index) {
    float size = 5.;
    vec3 total = vec3(0.);
    float weighting = 0.;
    float skips = 4.;
    vec2 base_normal = glyph_sample(uvOut(fragCoord,vec2(0.)), index).gb*2.-1.;
    base_normal = normalize(base_normal);
    
    for (float y=-size; y<size; y++) {
        for (float x=-size; x<size; x++) {
            vec2 pos = vec2(x*skips, y*skips);
            vec3 samp = glyph_sample(uvOut(fragCoord,pos), index);
            vec2 samp_normal = normalize(samp.gb*2.-1.);
            float weight = kernel(pos/size, skips);
            
            float weight_mask = max(dot(base_normal, samp_normal), 0.);
            weight *= weight_mask;
            
            total += samp*weight;
            weighting += weight;
        }
    }
    return total/weighting;
}
vec3 glyph_clear(vec3 col) {
    //iMouse.x/100.
    vec3 result = vec3(smoothstep(0.2, 0.85, col.x));
    //result = col;
    return result;
}

float index_number(float index, float num) {
    float i = index;
    if (index == 0.) {
        return 13.*16.+14.;
    } else if (index < 0.) {
        i += 1.;
    }
    float scale = pow(10., i);
    float shifted = abs(num)*scale;
    //shifted += 0.001; // elipson to fix 0.1 * 10 = 0.999 situations from resulting in 0.999 being floored away.
    float new = mod(floor(shifted), 10.);
    
    // negative and ()1.11 leading 0's to ( ) logic.
    if (new == 0.) {
        if ((floor(shifted) == 0. && floor(shifted*10.) != 0.) && num < 0.) { // if shifted is a fract, and if its *10 counterpart is not, and if num is negative.
            return 13.*16.+13.;
        } else if ((floor(shifted) == 0.) && floor(scale) == 0.) { // if shifted is a fract and if the scalar is a fract/ if digit is on the left side of the decimal.
            return 13.*16.;
        }
    }
    return new;
}
int translate_num(int index) {
    if (index > 9) {
        return index;
    } else {
        return index+12*16;
    }
}

// ---------------------------------------------------------------------------------------------
// gui_read
// ---------------------------------------------------------------------------------------------

vec4 text_read(vec2 fragCoord, vec2 real_fragCoord) {
    int inuse = 0;
    vec3 color;
    float scoping = 2.;
    vec2 spaceing = ((iResolution.xy)/float(line_max));

    vec2 coord = mod((fragCoord*float(line_max)),iResolution.xy);
    coord = coord/vec2(scoping, 1.)+vec2(spaceing.x*float(line_max)/4.,0.);
    
    vec2 i = vec2(fragCoord.x, iResolution.y-fragCoord.y);
    i = floor(i/spaceing);
    int index = int(i.x)+int(i.y)*line_max;
    
    ivec2 index_buffer_A = ivec2(index%int(iResolution.x), index/int(iResolution.x));
    vec4 samp = texelFetch(iChannel1, index_buffer_A, 0);
    index = int(samp.y);
    
    if (samp.x >= 0.) {
        vec4 data_samp = texelFetch(iChannel2, D_to_DD(int(samp.x)), 0);
        
        switch (int(round(data_samp.y))) {
            case 1:
                float number_index = (samp.w-samp.z)-data_samp.z;
                float num = index_number(number_index, (data_samp.x));
                index = translate_num(int(abs(num)));
                //int number = translate_num(int((samp.w-samp.z)-data_samp.z));
//vec3 glyph_sample(vec2 uv, float index) {

                //color = refine(coord, float(index));
                color = glyph_sample(uvOut(coord,vec2(0.)).xy, float(index));
                color = glyph_clear(color);
                color += 0.5;
                break;
            case 2:
                vec2 new_mouse = vec2(iMouse.x*1.0, iMouse.y); // warning 1.2 is arbitrary 
                float number_index2 = (samp.w-samp.z);

                vec2 base = fragCoord.xy-mod(fragCoord.xy, spaceing.x);
                float right = base.x-(number_index2*spaceing.x);
                float left = base.x+(samp.z*spaceing.x);
                float diff = right-left;
                float ratio_coord = (fragCoord.x-left)/diff;
                float diff_data = data_samp.w-data_samp.z;
                float ratio_data = (data_samp.w-data_samp.x)/diff_data;
                
                if (ratio_coord-ratio_data < 0.) {
                    color = vec3(0.1);
                } else {
                    color = vec3(0.5);
                }
                color += 1.-vec3(smoothstep(0.005,0.01,abs(ratio_coord-ratio_data)));
                float new;
                if (ivec2(real_fragCoord.xy) == ivec2(iMouse.xy) && iMouse.z > 0.) {
                    float ratio_mouse = 1.-(new_mouse.x-left)/diff;
                    float new = mix(data_samp.z, data_samp.w, ratio_mouse);
                    
                    inuse = 1;
                    color = vec3(new, samp.x, 0.);
                }
                break;
            case 3:
                float number_index4 = (samp.w-samp.z);

                vec2 base2 = mod(fragCoord, spaceing);
                base2.x /= scoping;
                base2 = base2/spaceing;
                base2 = base2*2.-1.;
                
                base2.x += 1.*(number_index4);
                float grey = 0.;
                grey = smoothstep(0.7, 0.75, max(abs(base2.x),abs(base2.y)))/2.;
                if (int(round(data_samp.x)) == 1) {
                    grey = max(1.-smoothstep(0.5, 0.55, length(base2)), grey);
                }

                color = vec3(grey);
                if (ivec2(real_fragCoord.xy) == ivec2(iMouse.xy) && (iMouse.z > 0. && iMouse.w > 0.)) {
                    inuse = 1;
                    color = vec3(abs(1.-data_samp.x), samp.x, 0.);
                }
                break;
            case 4:
                float number_index5 = (samp.w-samp.z);

                vec2 base3 = mod(fragCoord, spaceing);
                base3.x /= scoping;
                base3 = base3/spaceing;
                base3 = base3*2.-1.;
                
                base3.x += 1.*(number_index5);
                float grey1 = 0.;
                grey1 = 1.-smoothstep(0.5, 0.55, length(base3));

                color = vec3(grey1);
                if (ivec2(real_fragCoord.xy) == ivec2(iMouse.xy) && (iMouse.z > 0. && iMouse.w > 0.)) {      
                    inuse = 1;
                    color = vec3(abs(1.-data_samp.x), samp.x, 0.);
                }
                break;
            case 5:
                float number_index6 = (samp.w-samp.z);

                vec2 base4 = mod(fragCoord, spaceing);
                base4.x /= scoping;
                base4 = base4/spaceing;
                base4 = base4*2.-1.;
                
                base4.x += 1.*(number_index6);
                float grey2 = 0.;
                grey2 = 1.-smoothstep(0.5, 0.55, length(base4));

                color = vec3(grey2);
                break;
            default:
                float number_index3 = (samp.w-samp.z);
                float num2 = index_number(number_index, data_samp.y);
                index = translate_num(int(num));
                color = refine(coord, float(index));
        }
    } else {

        if (string[index] == 5) {
            float number_index6 = (samp.w-samp.z);

            vec2 base4 = mod(fragCoord, spaceing);
            base4.x /= scoping;
            base4 = base4/spaceing;
            base4 = base4*2.-1.;

            base4.x += 1.*(number_index6);
            float grey2 = 0.;
            grey2 = 1.-smoothstep(0.5, 0.55, length(base4));

            color = vec3(grey2);
        } else {
            if (string[index] == 140) {
                color = vec3(0.);
            } else if (index > string_length) {
                color = vec3(0.);
                index = translate_num(int(1));
                //color = refine(coord, float(string[index]));
                color = glyph_sample(uvOut(coord,vec2(0.)).xy, float(string[index]));

                color = glyph_clear(color);

            } else {
                //color = refine(coord, float(string[index]));
                color = glyph_sample(uvOut(coord,vec2(0.)).xy, float(string[index]));

                color = glyph_clear(color);
            }
        }
    }
    
    return vec4(color, inuse);
    //return vec4(vec3(scoped,0.), inuse);

}

// ---------------------------------------------------------------------------------------------
// main
// ---------------------------------------------------------------------------------------------

void mainImage( out vec4 fragColor, in vec2 fragCoord ) {
    vec2 a_2 = vec2(0.);
    vec2 b_2 = vec2(iResolution.x, iResolution.y*0.885);

    vec2 a = vec2(0., iResolution.y*0.885);
    vec2 b = vec2(iResolution.x, iResolution.y);

    if (within(a, b, fragCoord)) {
        vec4 samp = window(a, b, fragCoord, 12, 0., 2.);
        if (int(round(samp.w)) == 1) {
            vec2 coord = samp.xy*iResolution.xy;
            fragColor = text_read(coord, fragCoord);
        } else {
            fragColor = samp;
        }

    } else {
        //fragColor = vec4(box(a_2, b_2, fragCoord, 0., 1.), 0.);
        fragColor = texture(iChannel3, uvOut(fragCoord.xy, vec2(0.)));
        
        fragColor = vec4(fragColor.xyz, 0.);

    }
}