// Copyright (c) 2024 PaddlePaddle Authors. All Rights Reserved.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

#include "paddle/phi/core/kernel_registry.h"
#include "paddle/phi/kernels/impl/gru_kernel_impl.h"

namespace phi {

template <typename T, typename Context>
void GRUKernel(const Context &dev_ctx,
               const DenseTensor &input,
               const paddle::optional<DenseTensor> &h0,
               const DenseTensor &weight,
               const paddle::optional<DenseTensor> &bias,
               const std::string &activation,
               const std::string &gate_activation,
               bool is_reverse,
               bool origin_mode,
               bool is_test,
               DenseTensor *param_batch_gate,
               DenseTensor *param_batch_reset_hidden_prev,
               DenseTensor *param_batch_hidden,
               DenseTensor *hidden) {
  const T *weight_data = weight.data<T>();
  dev_ctx.template Alloc<T>(hidden);

  auto input_dims = input.dims();
  auto hidden_dims = hidden->dims();

  phi::DenseTensor *batch_gate;
  phi::DenseTensor *batch_reset_hidden_prev;
  phi::DenseTensor *batch_hidden;
  phi::DenseTensor batch_gate_tmp, batch_reset_hidden_prev_tmp,
      batch_hidden_tmp;
  if (is_test) {
    batch_gate = &batch_gate_tmp;
    batch_gate->Resize(input_dims);

    batch_reset_hidden_prev = &batch_reset_hidden_prev_tmp;
    batch_reset_hidden_prev->Resize(hidden_dims);

    batch_hidden = &batch_hidden_tmp;
    batch_hidden->Resize(hidden_dims);
  } else {
    batch_gate = param_batch_gate;
    batch_hidden = param_batch_hidden;
    batch_reset_hidden_prev = param_batch_reset_hidden_prev;
  }
  dev_ctx.template Alloc<T>(batch_gate);
  dev_ctx.template Alloc<T>(batch_reset_hidden_prev);
  dev_ctx.template Alloc<T>(batch_hidden);

  phi::funcs::DenseTensor2BatchFunctor<Context, T> to_batch;
  to_batch(dev_ctx, input, batch_gate, true, is_reverse);

  if (bias) {
    phi::funcs::RowwiseAdd<Context, T> add_bias;
    add_bias(dev_ctx, *batch_gate, *bias, batch_gate);
  }

  int frame_size = hidden_dims[1];
  phi::funcs::GRUMetaValue<T> gru_value;
  gru_value.gate_weight = const_cast<T *>(weight_data);
  gru_value.state_weight =
      const_cast<T *>(weight_data + 2 * frame_size * frame_size);
  phi::DenseTensor ordered_h0;

  phi::Vector<size_t> order(batch_gate->lod()[2]);

  if (h0) {
    // Since the batch computing for GRU reorders the input sequences
    // according to their length. The initialized cell state also needs
    // to reorder.
    ReorderInitState<Context, T>(dev_ctx, *h0, order, &ordered_h0, true);
    gru_value.prev_out_value = ordered_h0.data<T>();
  } else {
    gru_value.prev_out_value = nullptr;
  }
  auto batch_starts = batch_gate->lod()[0];
  size_t num_batch = batch_starts.size() - 1;
  auto active_node = phi::funcs::detail::GetActivationType(activation);
  auto active_gate = phi::funcs::detail::GetActivationType(gate_activation);
  for (size_t n = 0; n < num_batch; n++) {
    int bstart = static_cast<int>(batch_starts[n]);
    int bend = static_cast<int>(batch_starts[n + 1]);
    int cur_batch_size = bend - bstart;

    phi::DenseTensor gate_t = batch_gate->Slice(bstart, bend);
    phi::DenseTensor reset_hidden_prev_t =
        batch_reset_hidden_prev->Slice(bstart, bend);
    phi::DenseTensor hidden_t = batch_hidden->Slice(bstart, bend);
    gru_value.output_value = hidden_t.data<T>();
    gru_value.gate_value = gate_t.data<T>();
    gru_value.reset_output_value = reset_hidden_prev_t.data<T>();
    phi::funcs::GRUUnitFunctor<Context, T>::compute(dev_ctx,  // NOLINT
                                                    gru_value,
                                                    frame_size,
                                                    cur_batch_size,
                                                    active_node,
                                                    active_gate,
                                                    origin_mode);
    gru_value.prev_out_value = gru_value.output_value;
  }

  phi::funcs::Batch2DenseTensorFunctor<Context, T> to_seq;
  batch_hidden->set_lod(batch_gate->lod());
  to_seq(dev_ctx, *batch_hidden, hidden);
}
}  // namespace phi

PD_REGISTER_KERNEL(gru, GPU, ALL_LAYOUT, phi::GRUKernel, float, double) {}
