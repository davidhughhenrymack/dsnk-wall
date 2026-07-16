ivec2 D_to_DD(int index) {
    ivec2 i = ivec2(iResolution.xy);
    int lim = i.x*i.y;
    int index_clamp = clamp(index, 0, lim);
    int x = index_clamp%i.x;
    int y = index_clamp/i.x;
    return ivec2(x,y);
}
int new_line(int index_new) {
    int burn = (line_max)-index_new%(line_max);
    return burn;
}

int check_overflow(int index, int index_new) {
    int burn = new_line(index);
    int next_stop = index_new+burn;
    for (int x=index_new+1; x<next_stop; x++) {
        if (string[x] == 143) {
            return 0;
        }
    }
    return burn;
}
ivec2 extract(int index, int index_new) {
    int data = 0;
    int start = index_new+1;
    int count = 0;
    
    for (int x=start; x<start+10; x++) {
        if (string[x] == 143) {
            break;
        }
        data *= 10;
        data += string[x];
        count++;
    }
    return ivec2(data, count);
}
vec4 sample_scroll(int index) {
    ivec2 uv = D_to_DD(index);
    return texelFetch(iChannel0, uv, 0);
}
int next(int index_new, int index) {
    int start = index_new+1;
    int end = index_new+100;
    
    for (int x=start; x<end; x++) {
        if (string[x] == index) {
            return x-start;
        }
    }
    return 0;
}


void mainImage( out vec4 fragColor, in vec2 fragCoord ) {
    int index = int(fragCoord.x)+int(fragCoord.y)*int(iResolution.x);
    //int index_end = int(iResolution.x)*int(iResolution.y)-1;
    //int frame = (index+iFrame)%string_len; 

    // x: index of data, y: carry index, z: burn, w: burn_length
    // x: data, y: id of 1, z: n from d, w: n from d
    // x: data, y: id of 2, z: leftmost range, w: rightmost range 
    
    // with id of 1 from string[index] execution is as follows
    // burn is set to the data's range. 
    // data_location is extracted with extract();
    // index_new skips the data_location in the string.
    
    // during deployment with id of 1. 
    // if theres a data_location, its checked, if its 1 the following happens. 
    // does: burn-(range-data.z): samples digit with this value
    
    // with id of 2 from string[index] execution is as follows
    // burn is set to newline(). 
    // data_location is extracted with extract();
    // index_new skips the data_location in the string.
    
    // during deployment with id of 2. 
    // if theres a data_location, its checked, if its 2 the following happens. 
    // does: right = (range+index)*(iResolution.x/line-max): left = (index-(range-burn))*(iResolution.x/line-max)
    // it checks if mouse is clicking on itself, if (fragCoord.xy == iMouse.xy && (iMouse.z < 0 && iMouse.w < 0)) {...} 
    // if mouse is clicked, it super imposes: range = (right-clamp(mouse.x, right, left))/(right-left)
    // new = mix(data.z, data.w, range): and global variable data_set = data_location.
    // then it sets 
    
    int refresh_updates = 25;
    
    if (index == 0) {
        fragColor = vec4(-1., index, 0., 0.);
        return;
    } else {
        int back_track = max(index-refresh_updates, 1);
        
        vec4 prev = sample_scroll(back_track-1);
        if (int(round(prev.y)) >= string_length) {
            return;
        }
        for (int index_run=back_track; index_run<=index; index_run++) {            
            if (int(round(prev.z)) > 1) {
                vec4 next = vec4(prev.x, prev.y, prev.z-1., prev.w); // x: letter, y: carry index, z: burn, w: nothing
                prev = next;
            } else {
                int index_new = int(round(prev.y))+1;
                int letter = string[index_new];
                int burn = 0;
                int data_location = -1;
                int burn_length = 0;
                ivec2 extracted;
                switch (letter) {
                    case 143:
                        burn_length = check_overflow(index_run, index_new);
                        burn = burn_length;
                        break;
                    case 140:
                        burn_length = new_line(index_run);
                        burn = burn_length;
                        break;
                    case 1:
                        extracted = extract(index_run, index_new);
                        data_location = extracted.x;
                        index_new += extracted.y+1;

                        vec4 data = texelFetch(iChannel1, D_to_DD(data_location), 0);
                        burn_length = int(data.z)+int(data.w)+1;
                        burn = burn_length;
                        break;
                    case 2:
                        extracted = extract(index_run, index_new);
                        data_location = extracted.x;
                        index_new += extracted.y+1;

                        //vec4 data = texelFetch(iChannel1, D_to_DD(data_location), 0);
                        burn_length = new_line(index_run);
                        burn = burn_length;
                        break;
                    case 3:
                        extracted = extract(index_run, index_new);
                        data_location = extracted.x;
                        index_new += extracted.y+1;

                        burn_length = 2;
                        burn = burn_length;
                        break;
                    case 4:
                        extracted = extract(index_run, index_new);
                        data_location = extracted.x;
                        index_new += extracted.y+1;

                        vec4 data1 = texelFetch(iChannel1, D_to_DD(data_location), 0);
                        //index_new += next(index_new, 5);
                        if (int(round(data1.x)) == 0) {
                            index_new += next(index_new, 5);
                        }

                        burn_length = 2;
                        burn = burn_length;
                        break;
                    case 5:
                        burn_length = 2;
                        burn = burn_length;
                        break;
                }

                vec4 next = vec4(data_location, index_new, burn, burn_length); 
                prev = next;
            }
        }
        fragColor = prev;
    }
}