const EMPTY_DATEFORMAT = Dates.DateFormat("")

# Constructors
# independent constructor
function Source(fullpath::Union{AbstractString,IO};

              delim=COMMA,
              quotechar=QUOTE,
              escapechar=ESCAPE,
              null::AbstractString=String(""),

              header::Union{Integer,UnitRange{Int},Vector}=1, # header can be a row number, range of rows, or actual string vector
              datarow::Int=-1, # by default, data starts immediately after header or start of file
              types::Union{Dict{Int,DataType},Dict{String,DataType},Vector{DataType}}=DataType[],
              dateformat::Union{AbstractString,Dates.DateFormat}=EMPTY_DATEFORMAT,

              footerskip::Int=0,
              rows_for_type_detect::Int=100,
              rows::Int=0,
              use_mmap::Bool=true)
    # make sure character args are UInt8
    isascii(delim) || throw(ArgumentError("non-ASCII characters not supported for delim argument: $delim"))
    isascii(quotechar) || throw(ArgumentError("non-ASCII characters not supported for quotechar argument: $quotechar"))
    isascii(escapechar) || throw(ArgumentError("non-ASCII characters not supported for escapechar argument: $escapechar"))
    # isascii(decimal) || throw(ArgumentError("non-ASCII characters not supported for decimal argument: $decimal"))
    # isascii(separator) || throw(ArgumentError("non-ASCII characters not supported for separator argument: $separator"))
    delim = delim % UInt8
    quotechar = quotechar % UInt8
    escapechar = escapechar % UInt8
    decimal = CSV.PERIOD; decimal % UInt8
    separator = CSV.COMMA; separator % UInt8
    dateformat = isa(dateformat,Dates.DateFormat) ? dateformat : Dates.DateFormat(dateformat)
    return CSV.Source(fullpath=fullpath,
                        options=CSV.Options(delim,quotechar,escapechar,separator,
                                    decimal,ascii(null),null!="",dateformat,dateformat==Dates.ISODateFormat,-1,0,1,DataType[]),
                        header=header, datarow=datarow, types=types, footerskip=footerskip,
                        rows_for_type_detect=rows_for_type_detect, rows=rows, use_mmap=use_mmap)
end

function Source(;fullpath::Union{AbstractString,IO}="",
                options::CSV.Options=CSV.Options(),

                header::Union{Integer,UnitRange{Int},Vector}=1, # header can be a row number, range of rows, or actual string vector
                datarow::Int=-1, # by default, data starts immediately after header or start of file
                types::Union{Dict{Int,DataType},Dict{String,DataType},Vector{DataType}}=DataType[],

                footerskip::Int=0,
                rows_for_type_detect::Int=100,
                rows::Int=0,
                use_mmap::Bool=true)
    # delim=CSV.COMMA;quotechar=CSV.QUOTE;escapechar=CSV.ESCAPE;separator=CSV.COMMA;decimal=CSV.PERIOD;null="";header=1;datarow=2;types=DataType[];formats=UTF8String[];skipblankrows=true;footerskip=0;rows_for_type_detect=250;countrows=true
    # argument checks
    isa(fullpath,AbstractString) && (isfile(fullpath) || throw(ArgumentError("\"$fullpath\" is not a valid file")))
    isa(header,Integer) && datarow != -1 && (datarow > header || throw(ArgumentError("data row ($datarow) must come after header row ($header)")))

    isa(fullpath,IOStream) && (fullpath = chop(replace(fullpath.name,"<file ","")))

    # open the file for property detection
    parent = UInt8[]
    if isa(fullpath,IOBuffer)
        source = fullpath
        fullpath = "<IOBuffer>"
    elseif isdefined(fullpath, :gz_file) # hack to detect GZip.Stream
        source = fullpath
        fullpath = fullpath.name
    elseif isa(fullpath,IO)
        source = IOBuffer(readbytes(fullpath))
        fullpath = fullpath.name
        parent = source.data
    else
        source = IOBuffer(use_mmap ? Mmap.mmap(fullpath) : open(readbytes,fullpath))
        parent = source.data
    end
    options.datarow != -1 && (datarow = options.datarow)
    options.rows != 0 && (rows = options.rows)
    options.header != 1 && (header = options.header)
    options.types != DataType[] && (types = options.types)
    rows = rows == 0 ? CSV.countlines(source,options.quotechar,options.escapechar) : rows
    # rows == 0 && throw(ArgumentError("No rows of data detected in $fullpath"))
    seekstart(source)

    datarow = datarow == -1 ? (isa(header,Vector) ? 0 : last(header)) + 1 : datarow # by default, data starts on line after header
    rows = rows - datarow + 1 - footerskip # rows now equals the actual number of rows in the dataset

    # figure out # of columns and header, either an Integer, Range, or Vector{String}
    # also ensure that `f` is positioned at the start of data
    cols = 0
    if isa(header,Integer)
        # default header = 1
        if header <= 0
            CSV.skipto!(source,1,datarow,options.quotechar,options.escapechar)
            datapos = position(source)
            cols = length(CSV.readsplitline(source,options.delim,options.quotechar,options.escapechar))
            seek(source, datapos)
            columnnames = ["Column$i" for i = 1:cols]
        else
            CSV.skipto!(source,1,header,options.quotechar,options.escapechar)
            columnnames = [x for x in CSV.readsplitline(source,options.delim,options.quotechar,options.escapechar)]
            cols = length(columnnames)
            datarow != header+1 && CSV.skipto!(source,header+1,datarow,options.quotechar,options.escapechar)
            datapos = position(source)
        end
    elseif isa(header,Range)
        CSV.skipto!(source,1,first(header),options.quotechar,options.escapechar)
        columnnames = [x for x in readsplitline(source,options.delim,options.quotechar,options.escapechar)]
        cols = length(columnnames)
        for row = first(header):(last(header)-1)
            for (i,c) in enumerate([x for x in readsplitline(source,options.delim,options.quotechar,options.escapechar)])
                columnnames[i] *= "_" * c
            end
        end
        datarow != last(header)+1 && CSV.skipto!(source,last(header)+1,datarow,options.quotechar,options.escapechar)
        datapos = position(source)
    else
        CSV.skipto!(source,1,datarow,options.quotechar,options.escapechar)
        datapos = position(source)
        cols = length(readsplitline(source,options.delim,options.quotechar,options.escapechar))
        seek(source,datapos)
        if isempty(header)
            columnnames = ["Column$i" for i = 1:cols]
        else
            length(header) == cols || throw(ArgumentError("length of provided header doesn't match number of columns of data at row $datarow"))
            columnnames = header
        end
    end

    # Detect column types
    columntypes = Array(DataType,cols)
    if isa(types,Vector) && length(types) == cols
        columntypes = types
    elseif isa(types,Dict) || isempty(types)
        poss_types = Array(DataType,min(rows < 0 ? rows_for_type_detect : rows, rows_for_type_detect),cols)
        lineschecked = 0
        while !eof(source) && lineschecked < min(rows < 0 ? rows_for_type_detect : rows, rows_for_type_detect)
            vals = CSV.readsplitline(source,options.delim,options.quotechar,options.escapechar)
            lineschecked += 1
            for i = 1:cols
               poss_types[lineschecked,i] = CSV.detecttype(vals[i],options.dateformat,options.null)
            end
        end
        # detect most common/general type of each column of types
        d = Set{DataType}()
        for i = 1:cols
            for n = 1:lineschecked
                t = poss_types[n,i]
                t == NullField && continue
                push!(d,t)
            end
            columntypes[i] = (isempty(d) || WeakRefString{UInt8} in d ) ? WeakRefString{UInt8} :
                                (Date     in d) ? Date :
                                (DateTime in d) ? DateTime :
                                (Float64  in d) ? Float64 :
                                (Int      in d) ? Int : WeakRefString{UInt8}
            empty!(d)
        end
    else
        throw(ArgumentError("$cols number of columns detected; `types` argument has $(length(types)) entries"))
    end
    if isa(types,Dict{Int,DataType})
        for (col,typ) in types
            columntypes[col] = typ
        end
    elseif isa(types,Dict{String,DataType})
        for (col,typ) in types
            c = findfirst(columnnames, col)
            columntypes[c] = typ
        end
    end
    (any(columntypes .== DateTime) && options.dateformat == EMPTY_DATEFORMAT) && (options.dateformat = Dates.ISODateTimeFormat)
    (any(columntypes .== Date) && options.dateformat == EMPTY_DATEFORMAT) && (options.dateformat = Dates.ISODateFormat)
    seek(source,datapos)
    return Source(Data.Schema(columnnames,columntypes,rows,Dict("parent"=>parent)),
                  options,source,datapos,String(fullpath))
end

# construct a new Source from a Sink that has been streamed to (i.e. DONE)
function Source{I}(s::CSV.Sink{I})
    # Data.isdone(s) || throw(ArgumentError("::Sink has not been closed to streaming yet; call `close(::Sink)` first"))
    if is(I,IOStream)
        nm = String(chop(replace(s.data.name,"<file ","")))
        data = IOBuffer(Mmap.mmap(nm))
        s.schema.metadata["parent"] =  data.data
    else
        seek(s.data, s.datapos)
        data = IOBuffer(readbytes(s.data))
        nm = String("")
    end
    seek(data,s.datapos)
    return Source(s.schema,s.options,data,s.datapos,nm)
end

# Data.Source interface
Data.reset!(io::CSV.Source) = seek(io.data,io.datapos)
Data.isdone(io::CSV.Source, row, col) = eof(io.data)
Data.streamtype{T<:CSV.Source}(::Type{T}, ::Type{Data.Field}) = true
Data.getfield{T}(source::CSV.Source, ::Type{T}, row, col) = CSV.parsefield(source.data, T, source.options, row, col)

# function parsefield!{T}(io::IO, dest::NullableVector{T}, ::Type{T}, opts, row, col)
#     @inbounds val, null = CSV.parsefield(io, T, opts, row, col)
#     @inbounds dest.values[row], dest.isnull[row] = val, null
#     return
# end
#
# # parse data from `source` into a `DataFrame`
# function Data.stream!(source::CSV.Source,sink::DataFrame)
#     (Data.types(source) == Data.types(sink) &&
#     size(source) == size(sink)) || throw(ArgumentError("schema mismatch: \n$(Data.schema(source))\nvs.\n$(Data.schema(sink))"))
#     rows, cols = size(source)
#     types = Data.types(source)
#     io = source.data
#     opts = source.options
#     data = sink.columns
#     for row = 1:rows, col = 1:cols
#         @inbounds T = types[col]
#         CSV.parsefield!(io, data[col], T, opts, row, col)
#     end
#     return sink
# end

# "parse data from a `CSV.Source` into a `Feather.Sink`, feather-formatted binary file"
# function Data.stream!(source::CSV.Source,sink::Feather.Sink)
#
# end

"""

`CSV.read(fullpath::Union{AbstractString,IO}, sink=DataFrame)` => `typeof(sink)`

parses a delimited file into a Julia structure (a DataFrame by default, but any `Data.Sink` may be given).

Positional arguments:

* `fullpath`; can be a file name (string) or other `IO` instance
* `sink`; a `DataFrame` by default, but may also be other `Data.Sink` types that support the `AbstractTable` interface

Keyword Arguments:

* `delim::Union{Char,UInt8}`; how fields in the file are delimited
* `quotechar::Union{Char,UInt8}`; the character that indicates a quoted field that may contain the `delim` or newlines
* `escapechar::Union{Char,UInt8}`; the character that escapes a `quotechar` in a quoted field
* `null::String`; an ascii string that indicates how NULL values are represented in the dataset
* `header`; column names can be provided manually as a complete Vector{String}, or as an Int/Range which indicates the row/rows that contain the column names
* `datarow::Int`; specifies the row on which the actual data starts in the file; by default, the data is expected on the next row after the header row(s)
* `types`; column types can be provided manually as a complete Vector{DataType}, or in a Dict to reference a column by name or number
* `dateformat::Union{AbstractString,Dates.DateFormat}`; how all dates/datetimes are represented in the dataset
* `footerskip::Int`; indicates the number of rows to skip at the end of the file
* `rows_for_type_detect::Int=100`; indicates how many rows should be read to infer the types of columns
* `rows::Int`; indicates the total number of rows to read from the file; by default the file is pre-parsed to count the # of rows
* `use_mmap::Bool=true`; whether the underlying file will be mmapped or not while parsing

Note by default, "string" or text columns will be parsed as the `WeakRefString` type. This is a custom type that only stores a pointer to the actual byte data + the number of bytes.
To convert a `String` to a standard Julia string type, just call `string(::WeakRefString)`, this also works on an entire column `string(::NullableVector{WeakRefString})`.
Oftentimes, however, it can be convenient to work with `WeakRefStrings` depending on the ultimate use, such as transfering the data directly to another system and avoiding all the intermediate byte copying.

Example usage:
```
julia> dt = CSV.read("bids.csv")
7656334×9 DataFrames.DataFrame
│ Row     │ bid_id  │ bidder_id                               │ auction │ merchandise      │ device      │
├─────────┼─────────┼─────────────────────────────────────────┼─────────┼──────────────────┼─────────────┤
│ 1       │ 0       │ "8dac2b259fd1c6d1120e519fb1ac14fbqvax8" │ "ewmzr" │ "jewelry"        │ "phone0"    │
│ 2       │ 1       │ "668d393e858e8126275433046bbd35c6tywop" │ "aeqok" │ "furniture"      │ "phone1"    │
│ 3       │ 2       │ "aa5f360084278b35d746fa6af3a7a1a5ra3xe" │ "wa00e" │ "home goods"     │ "phone2"    │
...
```
"""
function read(fullpath::Union{AbstractString,IO}, sink=DataFrame;
              delim=COMMA,
              quotechar=QUOTE,
              escapechar=ESCAPE,
              null::AbstractString=String(""),
              header::Union{Integer,UnitRange{Int},Vector}=1, # header can be a row number, range of rows, or actual string vector
              datarow::Int=-1, # by default, data starts immediately after header or start of file
              types::Union{Dict{Int,DataType},Dict{String,DataType},Vector{DataType}}=DataType[],
              dateformat::Union{AbstractString,Dates.DateFormat}=EMPTY_DATEFORMAT,

              footerskip::Int=0,
              rows_for_type_detect::Int=100,
              rows::Int=0,
              use_mmap::Bool=true)
    source = Source(fullpath::Union{AbstractString,IO};
                  delim=delim,quotechar=quotechar,escapechar=escapechar,null=null,
                  header=header,datarow=datarow,types=types,dateformat=dateformat,
                  footerskip=footerskip,rows_for_type_detect=rows_for_type_detect,rows=rows,use_mmap=use_mmap)
    return Data.stream!(source,sink)
end
