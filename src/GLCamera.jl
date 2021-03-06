abstract Camera{T}
const Q = Quaternions # save some writing!

type OrthographicCamera{T} <: Camera{T}
    window_size     ::Signal{SimpleRectangle{Int}}
    view            ::Signal{Mat{4,4,T}}
    projection      ::Signal{Mat{4,4,T}}
    projectionview  ::Signal{Mat{4,4,T}}
end

type PerspectiveCamera{T} <: Camera{T}
    window_size     ::Signal{SimpleRectangle{Int}}
    nearclip        ::Signal{T}
    farclip         ::Signal{T}
    fov             ::Signal{T}
    view            ::Signal{Mat{4,4,T}}
    projection      ::Signal{Mat{4,4,T}}
    projectionview  ::Signal{Mat{4,4,T}}
    eyeposition     ::Signal{Vec{3, T}}
    lookat          ::Signal{Vec{3, T}}
    up              ::Signal{Vec{3, T}}
    trans           ::Signal{Vec{3, T}}
    theta           ::Signal{Vec{3, T}}
    projectiontype  ::Signal{Projection}
end

type DummyCamera{T} <: Camera{T}
    window_size     ::Signal{SimpleRectangle{Int}}
    view            ::Signal{Mat{4,4,T}}
    projection      ::Signal{Mat{4,4,T}}
    projectionview  ::Signal{Mat{4,4,T}}
end

function DummyCamera(;
        window_size    = Signal(SimpleRectangle(-1, -1, 1, 1)),
        view           = Signal(eye(Mat{4,4, Float32})),
        nearclip       = Signal(-10_000f0),
        farclip        = Signal(10_000f0),
        projection     = const_lift(orthographicprojection, window_size, nearclip, farclip),
        projectionview = const_lift(*, projection, view)
    )
    DummyCamera{Float32}(window_size, view, projection, projectionview)
end

function Base.collect(camera::Camera)
    collected = Dict{Symbol, Any}()
    names     = fieldnames(camera)
    for name in (:view, :projection, :projectionview, :eyeposition)
        if name in names
            collected[name] = getfield(camera, name)
        end
    end
    return collected
end


"""
Creates an orthographic camera with the pixel perfect plane in z == 0
Signals needed:
Dict(
    :window_size           => Signal(SimpleRectangle{Int}),
    :buttons_pressed       => Signal(Int[]),
    :mouse_buttons_pressed => Signal(Int[]),
    :mouseposition         => mouseposition, -> Panning
    :scroll_y              => Signal(0) -> Zoomig
)
"""
function OrthographicPixelCamera(
        inputs;
        fov=41f0, near=0.01f0, up=Vec3f0(0,1,0),
        translation_speed=Signal(1), theta=Signal(Vec3f0(0))
    )
    @materialize mouseposition, mouse_buttons_pressed, buttons_pressed, scroll = inputs
    left_ctrl     = Set([GLFW.KEY_LEFT_CONTROL])
    use_cam       = const_lift(==, buttons_pressed, left_ctrl)

    mouseposition = droprepeats(map(Vec2f0, mouseposition))
    left_pressed  = const_lift(pressed, mouse_buttons_pressed, GLFW.MOUSE_BUTTON_LEFT)
    xytranslate   = dragged_diff(mouseposition, left_pressed, use_cam)

    ztranslate    = filterwhen(use_cam, 0f0,
        const_lift(*, map(last, scroll), 5000f0)
    )
    trans = map(translationlift, xytranslate, ztranslate, translation_speed)
    OrthographicPixelCamera(
        theta, trans, Signal(up), Signal(fov), Signal(near),
        inputs[:window_area],
    )
end
function OrthographicPixelCamera(
        theta, trans, up, fov_s, near_s, area_s
    )
    fov, near = value(fov_s), value(near_s)

    # lets calculate how we need to adjust the camera, so that it mapps to
    # the pixel of the window (area)
    area = value(area_s)
    h = Float32(tan(fov / 360.0 * pi) * near)
    w_, h_ = area.w/2f0, area.h/2f0
    zoom = min(h_,w_)/h
    x, y = w_, h_
    eyeposition = Signal(Vec3f0(x, y, zoom))
    lookatvec   = Signal(Vec3f0(x, y, 0))
    far         = Signal(zoom*5.0f0) # this should probably be not calculated
    # since there is no scene independant, well working far clip

    PerspectiveCamera(
        theta,
        trans,
        lookatvec,
        eyeposition,
        up,
        area_s,
        fov_s, # Field of View
        near_s,  # Min distance (clip distance)
        far, # Max distance (clip distance)
        Signal(GLAbstraction.ORTHOGRAPHIC)
    )
end



pressed(keys, key) = key in keys
singlepressed(keys, key) = length(keys) == 1 && first(keys) == key

mouse_dragg(v0, args) = mouse_dragg(v0..., args...)
function mouse_dragg(
        started::Bool, startpoint, diff,
        ispressed::Bool, position, start_condition::Bool
    )
    if !started && ispressed && start_condition
        return (true, position, Vec2f0(0))
    end
    started && ispressed && return (true, startpoint, position-startpoint)
    (false, Vec2f0(0), Vec2f0(0))
end
mouse_dragg_diff(v0, args) = mouse_dragg_diff(v0..., args...)
function mouse_dragg_diff(
        started::Bool, position0, diff,
        ispressed::Bool, position, start_condition::Bool
    )
    if !started && ispressed && start_condition
        return (true, position, Vec2f0(0))
    end
    started && ispressed && return (true, position, position0-position)
    (false, Vec2f0(0), Vec2f0(0))
end

function dragged(mouseposition, key_pressed, start_condition=true)
    v0 = (false, Vec2f0(0), Vec2f0(0))
    args = const_lift(tuple, key_pressed, mouseposition, start_condition)
    dragg_sig = foldp(mouse_dragg, v0, args)
    is_dragg = map(first, dragg_sig)
    dragg = map(last, dragg_sig)
    dragg_diff = filterwhen(is_dragg, value(dragg), dragg)
    dragg_diff
end
function dragged_diff(mouseposition, key_pressed, start_condition=true)
    v0 = (false, Vec2f0(0), Vec2f0(0))
    args = const_lift(tuple, key_pressed, mouseposition, start_condition)
    dragg_sig = foldp(mouse_dragg_diff, v0, args)
    is_dragg = map(first, dragg_sig)
    dragg_diff = map(last, dragg_sig)
    dragg_diff
end





"""
Transforms a mouse drag into a selection from drag start to drag end
"""
function drag2selectionrange(v0, selection)
    mousediff, id_start, current_id = selection
    if mousediff != Vec2f0(0) # Mouse Moved
        if current_id[1] == id_start[1]
            return min(id_start[2],current_id[2]):max(id_start[2],current_id[2])
        end
    else # if mouse did not move while dragging, make a single point selection
        if current_id.id == id_start.id
            return current_id.index:0 # this is the type stable way of indicating, that the selection is between currend_index
        end
    end
    v0
end


"""
Returns two signals, one boolean signal if clicked over `robj` and another
one that consists of the object clicked on and another argument indicating that it's the first click
"""
function clicked(robj::RenderObject, button::MouseButton, window)
    @materialize mouse_hover, mousebuttonspressed = window.inputs
    clicked_on = const_lift(mouse_hover, mousebuttonspressed) do mh, mbp
        mh.id == robj.id && in(button, mbp)
    end
    clicked_on_obj = keepwhen(clicked_on, false, clicked_on)
    clicked_on_obj = const_lift((mh, x)->(x,robj,mh), mouse_hover, clicked_on)
    clicked_on, clicked_on_obj
end
export is_same_id
is_same_id(id_index, robj) = id_index.id == robj.id
"""
Returns a boolean signal indicating if the mouse hovers over `robj`
"""
is_hovering(robj::RenderObject, window) =
    droprepeats(const_lift(is_same_id, window.inputs[:mouse_hover], robj))



"""
returns a signal which becomes true whenever there is a doublecklick
"""
function doubleclick(mouseclick, threshold::Real)
    ddclick = foldp((time(), value(mouseclick), false), mouseclick) do v0, mclicked
        t0, lastc, _ = v0
        t1 = time()
        isclicked = (length(mclicked) == 1 &&
            length(lastc) == 1 &&
            first(lastc) == first(mclicked) &&
            t1-t0 < threshold
        )
        return (t1, mclicked, isclicked)
    end
    dd = const_lift(last, ddclick)
    return dd
end

export doubleclick

function default_camera_control(
        inputs, rotation_speed, translation_speed, keep=Signal(true)
    )
    @materialize mouseposition, mouse_buttons_pressed, scroll = inputs

    mouseposition = droprepeats(map(Vec2f0, mouseposition))
    left_pressed  = const_lift(pressed, mouse_buttons_pressed, GLFW.MOUSE_BUTTON_LEFT)
    right_pressed = const_lift(pressed, mouse_buttons_pressed, GLFW.MOUSE_BUTTON_RIGHT)
    xytheta       = dragged_diff(mouseposition, left_pressed, keep)
    xytranslate   = dragged_diff(mouseposition, right_pressed, keep)

    ztranslate    = filterwhen(keep, 0f0,
        const_lift(*, map(last, scroll), 120f0)
    )
    translate_theta(
        xytranslate, ztranslate, xytheta,
        rotation_speed, translation_speed
    )
end

function thetalift(xy, speed)
    Vec3f0(xy[1], -xy[2], 0f0).*speed
end
function translationlift(up_left, zoom, speed)
    Vec3f0(zoom, up_left[1], up_left[2]).*speed
end
function diff_vector(v0, p1)
    p0, diff = v0
    p1, p0-p1
end
function translate_theta(
        xytranslate, ztranslate, xytheta,
        rotation_speed, translation_speed
    )
    theta = map(thetalift, xytheta, rotation_speed)
    trans = map(translationlift, xytranslate, ztranslate, translation_speed)
    theta, trans
end

"""
Creates a perspective camera from a dict of signals
Args:

inputs: Dict of signals, looking like this:
[
    :window_size            => Signal(Vec{2, Int}),
    :buttons_pressed        => Signal(Int[]),
    :mouse_buttons_pressed  => Signal(Int[]),
    :mouseposition          => mouseposition, -> Panning + Rotation
    :scroll_y               => Signal(0) -> Zoomig
]
eyeposition: Position of the camera
lookatvec: Point the camera looks at
"""
function PerspectiveCamera{T}(
        inputs::Dict{Symbol,Any},
        eyeposition::Vec{3, T}, lookatvec::Vec{3, T}
    )
    theta, trans = default_camera_control(inputs, Signal(0.1f0), Signal(0.01f0))

    PerspectiveCamera(
        theta,
        trans,
        Signal(lookatvec),
        Signal(eyeposition),
        Signal(Vec3f0(0,0,1)),
        inputs[:window_area],
        Signal(41f0), # Field of View
        Signal(0.01f0),  # Min distance (clip distance)
        Signal(100f0) # Max distance (clip distance)
    )
end
function PerspectiveCamera{T}(
        area,
        eyeposition::Signal{Vec{3, T}}, lookatvec::Signal{Vec{3, T}}, upvector
    )
    PerspectiveCamera(
        Signal(Vec3f0(0)),
        Signal(Vec3f0(0)),
        lookatvec,
        eyeposition,
        upvector,
        area,
        Signal(41f0), # Field of View
        Signal(1f0),  # Min distance (clip distance)
        Signal(100f0) # Max distance (clip distance)
    )
end


function projection_switch{T<:Real}(
        wh::SimpleRectangle,
        fov::T, near::T, far::T,
        projection::Projection, zoom::T
    )
    aspect = T(wh.w/wh.h)
    h      = T(tan(fov / 360.0 * pi) * near)
    w      = T(h * aspect)
    projection == PERSPECTIVE && return frustum(-w, w, -h, h, near, far)
    h, w   = h*zoom, w*zoom
    orthographicprojection(-w, w, -h, h, near, far)
end



function translate_cam(
        translate,
        eyepos_s, lookat_s, up_s,
    )
    translate == Vec3f0(0) && return nothing # nothing to do

    lookat, eyepos, up = map(value, (lookat_s, eyepos_s, up_s))
    dir = normalize(eyepos - lookat)
    right = normalize(cross(dir, up))
    zoom_trans = dir*(translate[1])
    side_trans = right*(-translate[2]) + normalize(up)*translate[3]
    push!(eyepos_s, eyepos + side_trans + zoom_trans)
    push!(lookat_s, lookat + side_trans)
    nothing
end

function rotate_cam{T}(
        theta::Vec{3, T},
        cam_right::Vec{3,T}, cam_up::Vec{3,T}, cam_dir::Vec{3, T}
    )
    rotation = one(Q.Quaternion{T})
    # first the rotation around up axis, since the other rotation should be relative to that rotation
    if theta[1] != 0
        rotation *= Q.qrotation(cam_up, theta[1])
    end
    # then right rotation
    if theta[2] != 0
        rotation *= Q.qrotation(cam_right, theta[2])
    end
    # last rotation around camera axis
    if theta[3] != 0
        rotation *= Q.qrotation(cam_dir, theta[3])
    end
    rotation
end
"""
Creates a perspective camera from signals, controlling the camera
Args:

`window_size`: Size of the window

fov: Field of View
nearclip: Near clip plane
farclip: Far clip plane
`theta`: rotation around camera axis
`trans`: translation in camera space (xyz are the camera axes)
`lookatposition`: point the camera looks at
`eyeposition`: the actual position of the camera (the lense, the \"eye\")
"""
function PerspectiveCamera{T<:Vec3}(
        theta,
        trans::Signal{T},
        lookatposition::Signal{T},
        eyeposition::Signal{T},
        upvector::Signal{T},
        window_size,
        fov,
        nearclip,
        farclip,
        projectiontype = Signal(PERSPECTIVE)
    )
    # we have three ways to manipulate the camera: rotation, lookat/eyeposition and translation
    positions = (eyeposition, lookatposition, upvector)

    preserve(map(
       translate_cam, trans,
       Signal(eyeposition), Signal(lookatposition), Signal(upvector)
    ))

    preserve(map(theta) do theta_v
        theta_v == Vec3f0(0) && return nothing #nothing to do!
        eyepos_v, lookat_v, up_v = map(value, positions)

        dir = normalize(eyepos_v-lookat_v)
        right_v = normalize(cross(up_v, dir))
        up_v  = normalize(cross(dir, right_v))

        rotation = rotate_cam(theta_v, right_v, Vec3f0(0,0,1), dir)
        r_eyepos = lookat_v + rotation*(eyepos_v - lookat_v)
        r_up = normalize(rotation*up_v)
        push!(eyeposition, r_eyepos)
        push!(upvector, r_up)
    end)

    zoomlen = map(norm, map(-, lookatposition, eyeposition))
    projectionmatrix = map(projection_switch,
        window_size, fov, nearclip,
        farclip, projectiontype, zoomlen
    )

    # create the vievmatrix with the help of the lookat function
    viewmatrix = map(lookat, eyeposition, lookatposition, upvector)
    projectionview = map(*, projectionmatrix, viewmatrix)

    PerspectiveCamera{eltype(T)}(
        window_size,
        nearclip,
        farclip,
        fov,
        viewmatrix,
        projectionmatrix,
        projectionview,
        eyeposition, lookatposition, upvector,
        trans,
        theta,
        projectiontype
    )
end

"""
get's the boundingbox of a render object.
needs value, because boundingbox will always return a boundingbox signal
"""
signal_boundingbox(robj) = value(boundingbox(robj))


"""
Centers the camera on a list of render objects
"""
function center!(camera::PerspectiveCamera, renderlist::Vector)
    isempty(renderlist) && return nothing # nothing to do here
    # reset camera
    push!(camera.up, Vec3f0(0,0,1))
    push!(camera.eyeposition, Vec3f0(3))
    push!(camera.lookat, Vec3f0(0))

    robj1 = first(renderlist)
    bb = value(robj1[:model])*signal_boundingbox(robj1)
    for elem in renderlist[2:end]
        bb = union(value(elem[:model])*signal_boundingbox(elem), bb)
    end
    width        = widths(bb)
    half_width   = width/2f0
    lower_corner = minimum(bb)
    middle       = maximum(bb) - half_width
    if value(camera.projectiontype) == ORTHOGRAPHIC
        area, fov, near, far = map(value,
            (camera.window_size, camera.fov, camera.nearclip, camera.farclip)
        )
        aspect = Float32(area.w/area.h)
        h = Float32(tan(fov / 360.0 * pi) * near)
        w      = h * aspect
        w_, h_, _ = half_width
        if h_ > w_
            zoom = h_/h
        else
            zoom = w_/w
        end
        zoom = max(h_,w_)/h
        push!(camera.up, Vec3f0(0,1,0))
        x,y,_ = middle
        push!(camera.eyeposition, Vec3f0(x, y, zoom*1.2f0))
        push!(camera.lookat, Vec3f0(x, y, 0))
        push!(camera.farclip, zoom*20f0)

    else
        push!(camera.lookat, middle)
        neweyepos = middle + (width*1.2f0)
        push!(camera.eyeposition, neweyepos)
        push!(camera.up, Vec3f0(0,0,1))
        push!(camera.farclip, norm(width)*20f0)
    end
end

function renderlist() end
export renderlist

"""
Centers the camera(=:perspective) on all render objects in `window`
"""
function center!(window, camera=:perspective)
    center!(window.cameras[camera], renderlist(window))
end
