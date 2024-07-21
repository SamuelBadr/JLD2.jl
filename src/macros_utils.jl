
# Redefine unsafe_load, unsafe_store!, read, and write so that they pack the type
function define_packed(ty::DataType)
    @assert isbitstype(ty)
    packed_offsets = cumsum([jlsizeof(x) for x in ty.types])
    sz = pop!(packed_offsets)
    pushfirst!(packed_offsets, 0)

    if sz != jlsizeof(ty)
        @eval begin
            function jlunsafe_store!(p::Ptr{$ty}, x::$ty)
                $([:(jlunsafe_store!(pconvert(Ptr{$(ty.types[i])}, p+$(packed_offsets[i])), getfield(x, $i)))
                   for i = 1:length(packed_offsets)]...)
            end
            function jlunsafe_load(p::Ptr{$ty})
                $(Expr(:new, ty, [:(jlunsafe_load(pconvert(Ptr{$(ty.types[i])}, p+$(packed_offsets[i]))))
                                   for i = 1:length(packed_offsets)]...))
            end
            jlsizeof(::Union{$ty,Type{$ty}}) = $(Int(sz))::Int
        end
    end

    @eval begin
        @inline jlwrite(io::Union{MmapIO,BufferedWriter}, x::$ty) = _write(io, x)
        @inline jlread(io::Union{MmapIO,BufferedReader}, x::Type{$ty}) = _read(io, x)
        function jlread(io::IO, ::Type{$ty})
            $(Expr(:new, ty, [:(jlread(io, $(ty.types[i]))) for i = 1:length(packed_offsets)]...))
        end
        function jlwrite(io::IO, x::$ty)
            $([:(jlwrite(io, getfield(x, $i))) for i = 1:length(packed_offsets)]...)
            nothing
        end
    end
    nothing
end


###########################################################################################
# The following macro is used for declarative definition of Header Messages
###########################################################################################

macro pseudostruct(name, blck)
    constructor_body, size_body, messageshow_body = 
        build_fun_body((Any[], Any[], Any[]), blck)

    constructfun = :(function $(esc(:construct_hm_payload))(::Val{$name}, $(esc(:hflags)), $(esc(:hsize)), $(esc(:kw)))
            io = IOBuffer()
            $(constructor_body...)
            io
        end)

    size_fun = :(function $(esc(:sizefun))(::Val{$name}, $(esc(:hflags)), $(esc(:hsize)), $(esc(:kw)))
            $(esc(:offset)) = 0
            $(size_body...)
            return $(esc(:offset))
        end)

    message_show = :(function $(esc(:messageshow))(::Val{$name}, $(esc(:m))::Message, $(esc(:hflags))=0x0, $(esc(:hsize))=0x0000)
            $(esc(:io)) = m.io
            seek($(esc(:io)), m.address)
            $(esc(:offset)) = 0
            keyvalue = Pair{Symbol,Any}[]
            $(messageshow_body...)
            return keyvalue
        end)

    exprs = generate_getprop(blck.args)
    iogetpropfun = :(function $(esc(:iogetprop))(::Val{$name}, $(esc(:m))::Message, s::Symbol, $(esc(:hflags))=0x0, $(esc(:hsize))=0x0000)
            $(esc(:io)) = getfield(m, :io)
            $(esc.(exprs.args)...)
            throw(ArgumentError("Field $s not found"))
        end)

    ioexprfun = :(function $(esc(:ioexpr))(::Val{$name})
            return $(QuoteNode(exprs))
        end)

    return Expr(:block, iogetpropfun, constructfun, size_fun, message_show, ioexprfun, nothing)
end

function getprop end
function construct_hm_payload end
function sizefun end
function messageshow end
function ioexpr end



function linefun(ex)
    v = nothing
    kw = esc(:kw)
    io = esc(:io)
    offset = esc(:offset)
    if ex isa LineNumberNode
        return [ex, ex, ex]
    elseif @capture(ex, cond_ && body_)
        rets = linefun(ex.args[2])
        return [ Expr(:&&, esc(cond), ret ) for ret in rets ]
    elseif @capture(ex, if cond_; body_; end )
        accs = build_fun_body((Any[], Any[], Any[]), body)
        return [ Expr(:if, esc(cond), Expr(:block, accs[i]...)) for i in 1:length(accs) ]
    elseif @capture(ex, s_Symbol::T_) || @capture(ex, s_Symbol::T_ = v_)
        getprop_ = :($(esc(s)) = $kw.$(s))
        default = Symbol(s,"_default")
        default_ = :($default = $(esc(v)))
        get_ = :($(esc(s)) = get($kw, $(QuoteNode(s)), $default))
        haskey_ = :(haskey($kw, $(QuoteNode(s))) || throw(ArgumentError($("Argument $(QuoteNode(s)) is required"))))

        if @capture(T, @FixedLengthString(len_))
            len = esc(len)
            read_io = :(String(jlread($io, UInt8, $(len))))
            increment = :($len)
            write_statement = :(jlwrite(io, $(esc(s))))
        elseif @capture(T, @Blob(len_))
            len = esc(len)
            read_io = :(jlread($io, UInt8, $(len)))
            increment = :($len)
            write_statement = :(jlwrite(io, $(esc(s))))
        elseif @capture(T, @Int(len_))
            len = esc(len)
            read_io = quote
                uint = zero(UInt64)
                for i in 1:$len
                    uint = uint | jlread($io, UInt8) << ((i-1)*8)
                end
                uint
            end
            increment = :($len)
            write_statement = :(write_nb_int(io, $(esc(s)), $len))
        elseif @capture(T, @Offset)
            read_io = :(RelOffset(getfield(m,:offset) + position($io) - getfield(m,:address)))
            increment = 0
            getprop_ = nothing
            haskey_=nothing
            write_statement = nothing
        elseif @capture(T, @computed(expr_))
            @assert isnothing(v) "Defaults for @computed fields are not supported"
            read_io = read_statement = esc(expr)
            getprop_ = :($(esc(s)) = $(esc(expr)))
            increment = 0
            write_statement = nothing
            haskey_ = nothing
        elseif @capture(T, @read(type_, rsize_)) || @capture(T, @read(type_))
            read_io = :(jlread($io, $(esc(type))))
            write_statement = :(jlwrite(_io, $(esc(s))))
            if !isnothing(rsize)
                increment = esc(rsize)
            else
                increment = :(sizeof(typeof($(esc(s)))))
            end
        else
            T = esc(T)
            read_io = :(jlread($io, $T))
            increment = :(sizeof($(T)))
            write_statement = :(jlwrite(io, $T($(esc(s)))))
        end

        io_assign = :($(esc(s)) = $read_io)
        offset_incr = :($offset += $increment)
        
        return [
            # writing function
            if !isnothing(v)
                Expr(:block, default_, get_, write_statement)
            else
                Expr(:block, haskey_, getprop_, write_statement)
            end,
            # size function
            if !isnothing(v)
                Expr(:block, default_, get_, offset_incr)
            else
                Expr(:block, haskey_, getprop_, offset_incr)
            end,
            # pretty printer
            Expr(:block, io_assign,
                :(push!(keyvalue, $(QuoteNode(s)) => $(esc(s)))))
        ]
    elseif @capture(ex, @skip(n_))
        increment = esc(n)
        off_inc = :($offset += $increment)
        io_inc = :(skip($io, $increment))
        write_inc = :(write_zerobytes(io, $increment))
        return [write_inc, off_inc, off_inc]
    elseif @capture(ex, @skiptoaligned(n_))
        increment = :(8 - mod1($offset-$(esc(n)), 8))
        off_inc = :($offset += $increment)
        io_inc = :(skip($io, $increment))
        write_inc = :(write_zerobytes(io, $increment))
        return [write_inc, off_inc, io_inc]
    end
    throw(ArgumentError("Invalid field syntax: $ex"))
end

function build_fun_body(accs, blk)
    for ex in blk.args
        rets = linefun(ex)
        for i in 1:length(accs)
            push!(accs[i], rets[i])
        end
    end
    return accs
end




function generate_getprop(exprs, fields=[], precond=true)
    if exprs isa Expr && exprs.head==:block 
        return generate_getprop(exprs.args, fields, precond)
    end
    io = :io
    for ex in exprs
        io_assign = nothing
        if ex isa LineNumberNode
            continue
        elseif @capture(ex, cond_ && body_)
            combined_cond = precond==true ? cond : :($precond && $cond)
            generate_getprop([body], fields, combined_cond)
            continue
        elseif @capture(ex, if cond_; body_; end )
            combined_cond = precond==true ? cond : :($precond && $cond)
            generate_getprop(body.args, fields, combined_cond)
            continue
        elseif @capture(ex, s_Symbol::T_) || @capture(ex, s_Symbol::T_ = v_)
            if @capture(T, @FixedLengthString(len_))
                read_io = :(String(jlread($io, UInt8, $(len))))
                increment = :($len)
            elseif @capture(T, @Blob(len_))
                read_io = :(jlread($io, UInt8, $(len)))
                increment = :($len)
            elseif @capture(T, @Int(len_))
                read_io = quote
                    uint = zero(UInt64)
                    for i in 1:$len
                        uint = uint | jlread($io, UInt8) << ((i-1)*8)
                    end
                    uint
                end
                increment = :($len)
            elseif @capture(T, @Offset)
                read_io = :(RelOffset(getfield(m,:offset) + position($io) - getfield(m,:address)))
                increment = 0
            elseif @capture(T, @computed(expr_))
                read_io = expr
                increment = 0
            elseif @capture(T, @read(type_, rsize_)) || @capture(T, @read(type_))
                read_io = :(jlread($io, $(type)))
                increment = !isnothing(rsize) ? rsize :  :(sizeof(typeof(s)))
            else
                read_io = :(jlread($io, $T))
                increment = :(sizeof($(T)))
            end

            io_assign = :($(s) = $read_io)
    
        elseif @capture(ex, @skip(n_))
            increment = n
        elseif @capture(ex, @skiptoaligned(n_))
            increment = :(8 - mod1($offset-$(n), 8))
        else
            throw(ArgumentError("Invalid field syntax: $ex"))
        end

        push!(fields, (s, T, :(offset +=$increment), io_assign, precond))
    end
    return assemble_getprop(fields)
end

function filter_symbols(important_names, ex) 
    MacroTools.postwalk(ex) do ex
        if @capture(ex, s_Symbol)
            push!(important_names, s)
        end
    end
end

function assemble_getprop(fields_list)
    expr = Expr(:block)
    prep_statements = []
    important_names = Symbol[]
    for (nth, (s, T, increment, io_assign, cond)) in enumerate(fields_list)
        if isnothing(s)
            # must be a skip or so
            if cond == true
                push!(prep_statements, increment)
            else
                push!(prep_statements, Expr(:&&, cond, increment))
            end
            filter_symbols(important_names, increment)
            filter_symbols(important_names, cond)
            continue
        end
        
        filter_symbols(important_names, increment)
        filter_symbols(important_names, cond)
        filter_symbols(important_names, T)

        filtered_exps = Expr[]
        for prep in prep_statements
            if prep isa Expr
                push!(filtered_exps, prep)
            else
                sym, ex = prep
                if sym in important_names
                    push!(filtered_exps, ex)
                end
            end
        end

        if cond != true
            condexp = [:(if $(cond); $io_assign; return $s end)]
        else
            condexp = [io_assign,  :(return $s)]
        end
        getex = quote
            if s == $(QuoteNode(s))
                offset = getfield(m, :address)
                $(filtered_exps...)
                seek(io, offset)
                $(condexp...)
            end
        end
        push!(expr.args, getex.args[2])

        if cond == true
            push!(prep_statements, 
                (s,:(seek(io, offset))),
                (s, io_assign))
            push!(prep_statements, increment)
        else
            push!(prep_statements, (s, Expr(:if, cond, 
                Expr(:block, 
                    :(seek(io, offset)),
                    io_assign))))
            push!(prep_statements, Expr(:&&, cond, increment))
        end
    end
    return expr
end