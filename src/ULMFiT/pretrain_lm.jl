using DelimitedFiles

"""
ULMFiT - LANGUAGE MODEL

The Language model structure for ULMFit is defined by 'LanguageModel' struct.
It contains has two fields:
    vocab   : vocabulary, which will be used for language modelling
    layers  : embedding, RNN and dropout layers of the whole model
In this language model, the embedding matrix used in the embedding layer
is same for the softmax layer, following Weight-tying technique.
The field 'layers' also includes the Variational Dropout layers.
It takes several dropout probabilities for different dropout for different layers.

[Usage and arguments are discussed in the docs]

"""
mutable struct LanguageModel
    vocab :: Vector
    layers :: Flux.Chain
end

function LanguageModel(load_pretrained::Bool=false ;embedding_size::Integer=400, hid_lstm_sz::Integer=1150, out_lstm_sz::Integer=embedding_size,
    embed_drop_prob::Float64 = 0.05, in_drop_prob::Float64 = 0.4, hid_drop_prob::Float64 = 0.5, layer_drop_prob::Float64 = 0.3, final_drop_prob::Float64 = 0.3)
    vocab = intern.(string.(readdlm("vocab.csv",',', header=false)[:, 1]))
    de = gpu(DroppedEmbeddings(length(vocab), embedding_size, embed_drop_prob; init = (dims...) -> init_weights(0.1, dims...)))
    lm = LanguageModel(
        vocab,
        Chain(
            de,
            VarDrop(in_drop_prob),
            gpu(AWD_LSTM(embedding_size, hid_lstm_sz, hid_drop_prob; init = (dims...) -> init_weights(1/hid_lstm_sz, dims...))),
            VarDrop(layer_drop_prob),
            gpu(AWD_LSTM(hid_lstm_sz, hid_lstm_sz, hid_drop_prob; init = (dims...) -> init_weights(1/hid_lstm_sz, dims...))),
            VarDrop(layer_drop_prob),
            gpu(AWD_LSTM(hid_lstm_sz, out_lstm_sz, hid_drop_prob; init = (dims...) -> init_weights(1/hid_lstm_sz, dims...))),
            VarDrop(final_drop_prob),
            x -> de(x, true),
            softmax
        )
    )
    load_pretrained && load_model!(lm, datadep"Pretrained ULMFiT Language Model")
    return lm
end

Flux.@treelike LanguageModel

# Tests the language model
function test_lm(lm, data_gen, num_of_iters::Integer; unknown_token::String="_unk_")
    model_layers = mapleaves(Tracker.data, lm.layers)
    testmode!(model_layers)
    sum_l, l_vect = 0, []
    len = length(vocab)
    TP, FP, FN, TN = zeros(len, 1), zeros(len, 1), zeros(len, 1), zeros(len, 1)
    for iter=1:num_of_iters
        x, y = take!(gen), take!(gen)
        h = broadcast(w -> indices(w, lm.vocab, unknown_token), x)
        h = model_layers.(h)
        y = broadcast(x -> gpu(Flux.onehotbatch(x, lm.vocab, "_unk_")), y)
        l = sum(crossentropy.(h, y))
        Flux.reset!(model_layers)
        tp, tn, fp, fn = confusion_matrix(h, y)
        TP .+= tp
        TN .+= tn
        FP .+= fp
        FN .+= fn
        sum_l += l
        push!(l_vect, l)
    end
    precisions = TP./(TP .+ FP)
    recalls = TP./(TP .+ FN)
    F1 = (2 .* (precisions .* recalls))./(precisions .+ recalls)
    return sum_l/num_of_iters, l_vect, precisions, recalls, F1
end

# computes the forward pass while training
function forward(lm, batch)
    batch = map(x -> indices(x, lm.vocab, "_unk_"), batch)
    batch = lm.layers.(batch)
    return batch
end

# loss funciton - Calculates crossentropy loss
function loss(lm, gen)
    H = forward(lm, take!(gen))
    Y = broadcast(x -> gpu(Flux.onehotbatch(x, lm.vocab, "_unk_")), take!(gen))
    l = sum(crossentropy.(H, Y))
    Flux.truncate!(lm.layers)
    return l
end

# Backpropagation step while training
function backward!(layers, l, opt)
    # Calulating gradients and weights updation
    p = get_trainable_params(layers)
    grads = Tracker.gradient(() -> l, p)
    Tracker.update!(opt, p, grads)
    return
end

"""
pretrain_lm!

This funciton contains main training loops for pretrainin the Language model
including averaging step for the 'AWD_LSTM' layers.

Usage and arguments are explained in the docs of ULMFiT
"""
function pretrain_lm!(lm::LanguageModel=LanguageModel(), data_loader::Channel=load_wikitext_103;
    base_lr=0.004, epochs::Integer=1, checkpoint_iter::Integer=5000)

    # Initializations
    opt = ADAM(base_lr, (0.7, 0.99))    # ADAM Optimizer

    # Pre-Training loops
    for epoch=1:epochs
        println("\nEpoch: $epoch")
        gen = data_loader()
        num_of_batches = take!(gen) # Number of mini-batches
        T = num_of_iters-Int(floor((num_of_iters*2)/100))   # Averaging Trigger
        set_trigger!.(T, lm.layers)  # Setting triggers for AWD_LSTM layers
        for i=1:num_of_batches

            # FORWARD PASS
            l = loss(lm, gen)

            # REVERSE PASS
            backward!(lm.layers, l, opt)

            # ASGD Step, works after Triggering
            asgd_step!.(i, lm.layers)

            # Resets dropout masks for all the layers with Varitional DropOut or DropConnect masks
            reset_masks!.(lm.layers)

            # Saving checkpoints
            if i == checkpoint_iter save_model!(lm) end
        end
    end
end

# To save model
function save_model!(m::LanguageModel, filepath::String)
    weights = cpu.(Tracker.data.(params(m)))
    @save filepath weights
end

# To load model
function load_model!(lm::LanguageModel, filepath::String)
    @load filepath weights
    Flux.loadparams!(lm, weights)
end

"""
sample(starting_text::AbstractDocument, lm::LanguageModel)

Prints sampling results taking `starting_text` as initial tokens for the sampling for LanguageModel.

# Example:

julia> sampling("computer science", lm)
SAMPLING...
, is fast growing field ......

"""
function sample(starting_text::AbstractDocument, lm::LanguageModel)
    testmode!(lm.layers)
    model_layers = mapleaves(Tracker.data, lm.layers)
    tokens = tokens(starting_text)
    word_indices = map(x -> indices([x], lm.vocab, "_unk_"), tokens)
    h = (model_layers.(word_indices))[end]
    prediction = lm.vocab[argmax(h)[1]]
    println("SAMPLING...")
    print(prediction, ' ')
    while true
        h = indices([prediction], lm.vocab, "_unk_")
        h = model_layers(h)
        prediction = lm.vocab[argmax(h)[1]]
        print(prediction, ' ')
        prediction == "_pad_" && break
    end
end


# using WordTokenizers   # For accesories
# using InternedStrings   # For using Interned strings
# using Flux  # For building models
# using Flux: Tracker, crossentropy, chunk
# using BSON: @save, @load  # For saving model weights
# using CuArrays  # For GPU support
